/*
 * ws2812-common -- drive WS2812 strips behind an SPI MOSI line.
 *
 * The NGP45HT ties its two analog-stick RGB rings to SPI0 (GPIO3_B5 = MOSI,
 * GPIO3_B4 = CLK) with no controller chip in between: the strips are plain
 * WS2812 chains, eight LEDs each, so the SPI bus itself has to emit the
 * WS2812 waveform.  One SPI byte encodes one WS2812 bit at 8 MHz:
 *
 *      0 bit -> 0xC0  (1110 0000, ~0.375 us high)
 *      1 bit -> 0xFC  (1111 1100, ~0.75  us high)
 *
 * which lands inside the WS2812B tolerance window (T0H 0.35/0.8 us,
 * T1H 0.7/1.0 us) without any bit-banging.  A frame is 24 bits per LED in
 * G,R,B order, latched by holding MOSI low for >50 us -- done here by
 * sending a run of zero bytes and then sleeping, which is also what makes a
 * full-black frame stick.
 *
 * Why this exists instead of an opaque vendor blob: the OFF path is the part
 * everyone gets wrong.  The ROCKNIX binary exits without writing anything for
 * "OFF", and because WS2812 latches its last frame, the rings stay lit.  Here
 * OFF is a real all-zero frame, so it actually goes dark.
 *
 * Usage:
 *   ws2812-common --device /dev/spidev0.0 off
 *   ws2812-common --device /dev/spidev0.0 color RRGGBB
 *   ws2812-common --device /dev/spidev0.0 effect <name> [RRGGBB]
 *   ws2812-common --device /dev/spidev0.0 run        (persistent animator)
 *
 * Effects that animate (breath, scroll, rainbow) are rendered once into a
 * frame buffer and re-sent; "run" keeps the process alive stepping frames so
 * a systemd unit can supervise it.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <linux/spi/spidev.h>
#include <sys/ioctl.h>

#define DEFAULT_DEV   "/dev/spidev0.0"
#define DEFAULT_HZ    8000000
#define DEFAULT_LEDS  8

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

struct spi_ctx {
	int fd;
	uint32_t hz;
	size_t nled;
	uint8_t *buf;
	size_t buflen;
};

static int spi_open(struct spi_ctx *s, const char *dev, uint32_t hz, size_t nled)
{
	uint8_t mode = SPI_MODE_0;
	uint8_t bits = 8;

	s->hz = hz;
	s->nled = nled;
	/* 24 bits per LED, one byte per bit.  Pad by 32 bytes of "low" so the
	 * strip definitely sees its latch gap after the last bit. */
	s->buflen = nled * 24 + 32;
	s->buf = calloc(1, s->buflen);
	if (!s->buf)
		return -1;

	s->fd = open(dev, O_RDWR);
	if (s->fd < 0)
		return -1;

	if (ioctl(s->fd, SPI_IOC_WR_MODE, &mode) < 0 ||
	    ioctl(s->fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
	    ioctl(s->fd, SPI_IOC_WR_MAX_SPEED_HZ, &s->hz) < 0) {
		close(s->fd);
		s->fd = -1;
		return -1;
	}
	return 0;
}

/* Push s->buf out in one transfer. */
static int spi_flush(struct spi_ctx *s)
{
	struct spi_ioc_transfer tr = { 0 };

	tr.tx_buf = (unsigned long)s->buf;
	tr.len = (uint32_t)s->buflen;
	tr.speed_hz = s->hz;
	tr.bits_per_word = 8;
	tr.delay_usecs = 0;

	if (ioctl(s->fd, SPI_IOC_MESSAGE(1), &tr) < 0)
		return -1;
	/* Latch: the strips commit when the line stays low for a while. */
	usleep(300);
	return 0;
}

/* Paint one LED's 24 bits into the frame buffer, GRB order. */
static void put_led(struct spi_ctx *s, size_t idx, uint8_t r, uint8_t g, uint8_t b)
{
	uint8_t *p = s->buf + idx * 24;
	uint8_t v[3] = { g, r, b };
	int i;

	for (i = 0; i < 24; i++) {
		int bit = (v[i / 8] >> (7 - (i % 8))) & 1;
		p[i] = bit ? 0xFC : 0xC0;
	}
}

static void fill(struct spi_ctx *s, uint8_t r, uint8_t g, uint8_t b)
{
	size_t i;

	for (i = 0; i < s->nled; i++)
		put_led(s, i, r, g, b);
	/* Tail padding must be 0x00 (real low), not 0xC0. */
	memset(s->buf + s->nled * 24, 0, s->buflen - s->nled * 24);
}

/* HSV -> RGB, h in degrees, s/v in 0..1. */
static void hsv2rgb(double h, double sat, double v,
		    uint8_t *r, uint8_t *g, uint8_t *b)
{
	double c = v * sat;
	double x = c * (1.0 - fabs(fmod(h / 60.0, 2.0) - 1.0));
	double m = v - c;
	double rr = 0, gg = 0, bb = 0;

	if (h < 60)       { rr = c; gg = x; }
	else if (h < 120) { rr = x; gg = c; }
	else if (h < 180) { gg = c; bb = x; }
	else if (h < 240) { gg = x; bb = c; }
	else if (h < 300) { rr = x; bb = c; }
	else              { rr = c; bb = x; }

	*r = (uint8_t)lround((rr + m) * 255.0);
	*g = (uint8_t)lround((gg + m) * 255.0);
	*b = (uint8_t)lround((bb + m) * 255.0);
}

static int parse_hex(const char *s, uint8_t *r, uint8_t *g, uint8_t *b)
{
	unsigned int v;

	if (!s || strlen(s) != 6 || sscanf(s, "%06x", &v) != 1)
		return -1;
	*r = (v >> 16) & 0xff;
	*g = (v >> 8) & 0xff;
	*b = v & 0xff;
	return 0;
}

static void msleep(long ms)
{
	struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

/* One animation step.  Returns how long to sleep before the next one. */
static long step_effect(struct spi_ctx *s, const char *eff,
			uint8_t r, uint8_t g, uint8_t b, double *phase)
{
	const double two_pi = 6.283185307179586;
	size_t i;

	if (!strcmp(eff, "breath")) {
		/* Ease in/out so the low end is not a flicker. */
		double k = 0.5 - 0.5 * cos(*phase * two_pi);
		double lo = 0.06, hi = 1.0;   /* never fully off mid-breath */
		double v = lo + (hi - lo) * k;

		fill(s, (uint8_t)(r * v), (uint8_t)(g * v), (uint8_t)(b * v));
		spi_flush(s);
		*phase += 1.0 / 60.0;         /* ~2 s per cycle at 30 ms */
		return 30;
	}

	if (!strcmp(eff, "rainbow")) {
		for (i = 0; i < s->nled; i++) {
			double h = fmod(*phase * 360.0 + (360.0 * i) / s->nled, 360.0);
			uint8_t rr, gg, bb;

			hsv2rgb(h, 1.0, 1.0, &rr, &gg, &bb);
			put_led(s, i, rr, gg, bb);
		}
		spi_flush(s);
		*phase += 0.004;
		return 25;
	}

	if (!strcmp(eff, "scroll")) {
		/* A single lit LED walking around the ring. */
		size_t pos = (size_t)(*phase) % s->nled;

		fill(s, 0, 0, 0);
		for (i = 0; i < s->nled; i++) {
			size_t d = (i + s->nled - pos) % s->nled;
			double k = d == 0 ? 1.0 : (d == 1 ? 0.35 : 0.0);

			put_led(s, i, (uint8_t)(r * k), (uint8_t)(g * k), (uint8_t)(b * k));
		}
		spi_flush(s);
		*phase += 1.0;
		return 90;
	}

	/* Unknown / static: solid colour, no animation. */
	fill(s, r, g, b);
	spi_flush(s);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: ws2812-common [--device DEV] [--leds N] [--hz HZ] CMD\n"
		"  off                     all LEDs dark (a real all-zero frame)\n"
		"  color RRGGBB            solid colour, static\n"
		"  effect NAME [RRGGBB]    breath | rainbow | scroll | solid\n"
		"  run NAME [RRGGBB]       animate until SIGTERM (systemd mode)\n");
}

int main(int argc, char **argv)
{
	static const struct option opts[] = {
		{ "device", required_argument, NULL, 'd' },
		{ "leds",   required_argument, NULL, 'n' },
		{ "hz",     required_argument, NULL, 's' },
		{ "help",   no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	const char *dev = DEFAULT_DEV;
	uint32_t hz = DEFAULT_HZ;
	size_t nled = DEFAULT_LEDS;
	struct spi_ctx s = { .fd = -1 };
	uint8_t r = 0, g = 0, b = 0;
	const char *cmd, *eff = "solid";
	int c, rc = 1, animate = 0;

	while ((c = getopt_long(argc, argv, "d:n:s:h", opts, NULL)) != -1) {
		switch (c) {
		case 'd': dev = optarg; break;
		case 'n': nled = (size_t)strtoul(optarg, NULL, 0); break;
		case 's': hz = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'h': usage(); return 0;
		default:  usage(); return 2;
		}
	}
	if (optind >= argc) {
		usage();
		return 2;
	}
	cmd = argv[optind++];

	if (nled == 0 || nled > 512) {
		fprintf(stderr, "ws2812: implausible LED count %zu\n", nled);
		return 2;
	}

	if (spi_open(&s, dev, hz, nled) < 0) {
		fprintf(stderr, "ws2812: cannot open %s: %s\n", dev, strerror(errno));
		return 1;
	}

	if (!strcmp(cmd, "off")) {
		fill(&s, 0, 0, 0);
		rc = spi_flush(&s) == 0 ? 0 : 1;
		goto out;
	}

	if (!strcmp(cmd, "color")) {
		if (optind >= argc || parse_hex(argv[optind], &r, &g, &b) < 0) {
			fprintf(stderr, "ws2812: color needs RRGGBB\n");
			goto out;
		}
		fill(&s, r, g, b);
		rc = spi_flush(&s) == 0 ? 0 : 1;
		goto out;
	}

	if (!strcmp(cmd, "effect") || !strcmp(cmd, "run")) {
		animate = !strcmp(cmd, "run");
		if (optind < argc)
			eff = argv[optind++];
		if (optind < argc) {
			if (parse_hex(argv[optind], &r, &g, &b) < 0) {
				fprintf(stderr, "ws2812: bad colour %s\n", argv[optind]);
				goto out;
			}
		} else {
			/* Default accent: a warm orange, visible but not harsh. */
			r = 0xff; g = 0x60; b = 0x00;
		}

		if (!animate) {
			double phase = 0.0;
			step_effect(&s, eff, r, g, b, &phase);
			rc = 0;
			goto out;
		}

		signal(SIGTERM, on_signal);
		signal(SIGINT, on_signal);
		{
			double phase = 0.0;

			while (!g_stop) {
				long d = step_effect(&s, eff, r, g, b, &phase);

				if (d <= 0)
					d = 1000;   /* static effect: idle */
				msleep(d);
			}
		}
		fill(&s, 0, 0, 0);
		spi_flush(&s);
		rc = 0;
		goto out;
	}

	fprintf(stderr, "ws2812: unknown command %s\n", cmd);
	usage();

out:
	if (s.fd >= 0)
		close(s.fd);
	free(s.buf);
	return rc;
}
