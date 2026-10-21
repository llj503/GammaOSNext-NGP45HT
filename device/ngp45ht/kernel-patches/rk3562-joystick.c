// SPDX-License-Identifier: GPL-2.0-only
/*
 * RK3562 handheld gamepad driver
 *
 * Generic input driver for RK3562-based handheld gamepads (RG52 Mini,
 * RG43H Pro, etc.).  Reads analog sticks and triggers via IIO (SARADC),
 * ADC-threshold buttons via IIO, and GPIO-connected buttons via IRQ
 * with debounce.
 *
 * Features:
 * - IRQ-driven GPIO buttons with configurable debounce
 * - Dynamic GPIO button count (read from DT key-gpios-map)
 * - Force feedback (rumble) via GPIO-connected motors
 * - Left/right stick X/Y axis swap (DT properties)
 * - Left stick polarity inversion (DT property "left-stick-invert")
 * - Axis-to-dpad mode via sysfs
 *
 * Note: The stock zed_joystick driver reads l_x_swap, l_y_swap, r_x_swap,
 * and r_y_swap DT properties but never uses them for axis inversion.
 * We match that behavior by ignoring these properties entirely.
 *
 * Compatible with the "play_joystick" device tree node shipped in the
 * stock RK3562 firmware.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/input.h>
#include <linux/iio/consumer.h>
#include <linux/gpio/consumer.h>
#include <linux/of.h>
#include <linux/property.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/pm.h>
#include <linux/delay.h>
#include <linux/slab.h>

#define DRIVER_NAME	"rk3562-joystick"
#define MOUSE_NAME	"rk3562-mouse"

#define HOLD_MS		300	/* R3 hold threshold for scroll mode */
#define CHORD_MS	80	/* L3+R3 chord window */
#define MOUSE_MAX_STEP	12	/* max px per 16ms poll at full stick deflection */
#define SCROLL_MAX_STEP	1	/* max wheel ticks per poll at full deflection */
#define Y_INVERT	1	/* set to -1 if vertical inverted */

/* Number of stick axes (LX, LY, RX, RY) */
#define NUM_STICK_CHANS	4
/* Number of trigger axes (L2, R2) */
#define NUM_TRIG_CHANS	2
/* Number of ADC-threshold buttons (dpad L/R/D, B, X, Y) */
#define NUM_ADC_BTNS	6

/* Reported axis range to userspace */
#define AXIS_MIN	-32767
#define AXIS_MAX	32767
#define TRIG_MIN	0
#define TRIG_MAX	32767

/* Axis-to-dpad threshold: ~55% of 32767 = 18000 */
#define DPAD_THRESHOLD	18000

/* Default debounce interval in ms -- silicone-dampened microswitches settle in 1-3ms */
#define DEFAULT_DEBOUNCE_MS	5

/* Auto-calibration parameters */
#define CALIBRATION_SAMPLES	16	/* readings to average at probe */
#define CALIBRATION_DELAY_US	1000	/* 1ms between samples */

/* Stick: dead zone is center +/- this margin (in microvolts) */
#define STICK_DZ_MARGIN_UV	110000	/* 110mV -- matches DT's ~110mV half-width */

/* Trigger: consistent fully-pressed floor (in microvolts) */
#define TRIG_MIN_UV		11000	/* 11mV observed */
/* Trigger: dead zone near rest -- suppress noise below this output value.
 * L2 noise peaks at ~536, R2 at ~77 on 0-32767 scale. 800 gives margin. */
#define TRIG_DZ_OUTPUT		6
/* Trigger: calibrated fuzz/flat (much smaller than pre-calibration values) */
#define TRIG_FLAT_CALIBRATED	512
#define TRIG_FUZZ_CALIBRATED	64

/* DTS key codes that need remapping to BTN_* range for joydev visibility */
#define KEY_HOME_DTS	102
#define KEY_FN_DTS	464

struct rk3562_joystick;

struct rk3562_gpio_btn {
	struct gpio_desc *gpiod;
	unsigned int code;
	int irq;
	int index;
	struct delayed_work work;
	struct rk3562_joystick *joy;
};

struct rk3562_joystick {
	struct device *dev;
	struct input_dev *input;

	/* IIO channels */
	struct iio_channel *stick_chans[NUM_STICK_CHANS];
	struct iio_channel *trig_chans[NUM_TRIG_CHANS];
	struct iio_channel *adc_btn_chans[NUM_ADC_BTNS];

	/* Channels actually present in the DT.  Triggers and ADC buttons are
	 * optional: boards whose shoulders/d-pad/face buttons are all on GPIO
	 * (e.g. NGP45HT) declare only the 4 stick channels. */
	int num_trig;
	int num_adc_btn;

	/* GPIO buttons (IRQ-driven, dynamically sized) */
	struct rk3562_gpio_btn *gpio_btns;
	int num_gpio_btns;
	unsigned int debounce_ms;

	/* ADC button codes and thresholds */
	unsigned int adc_btn_codes[NUM_ADC_BTNS];
	int adc_btn_thresh[NUM_ADC_BTNS]; /* in microvolts */

	/* Stick calibration (millivolts from DTS, converted to microvolts) */
	int axis_min_uv;
	int axis_max_uv;
	int axis_dz_lo_uv[NUM_STICK_CHANS];  /* per-axis dead zone low */
	int axis_dz_hi_uv[NUM_STICK_CHANS];  /* per-axis dead zone high */

	/* Trigger calibration (millivolts from DTS, converted to microvolts) */
	int trig_min_uv;
	int trig_max_uv[NUM_TRIG_CHANS];  /* per-trigger resting voltage */

	/* Axis X/Y swap flags */
	bool l_xy_swap;
	bool r_xy_swap;

	/* Left stick polarity inversion (for devices where the left stick
	 * module is physically rotated 180 degrees, e.g. RG52 Mini) */
	bool left_stick_invert;

	/* Per-axis polarity inversion (DT: invert-x/-y/-rx/-ry) */
	bool inv_absx;
	bool inv_absy;
	bool inv_abtrx;
	bool inv_abtry;

	/* Rumble motors (optional) */
	struct gpio_desc *moto_gpio;
	struct gpio_desc *moto_r_gpio;
	bool rumble_on;

	/* Axis-to-dpad mode */
	bool axis_to_dpad;
	bool last_dpad_up;
	bool last_dpad_down;
	bool last_dpad_left;
	bool last_dpad_right;

	/* Physical D-pad button states (V148: hat source, not the stick) */
	bool dpad_up;		/* GPIO BTN_DPAD_UP */
	bool dpad_left;		/* GPIO BTN_DPAD_LEFT */
	bool dpad_right;	/* GPIO BTN_DPAD_RIGHT */
	bool dpad_down;		/* GPIO BTN_DPAD_DOWN */
	int last_hat_x;		/* last reported ABS_HAT0X, for edge detection */
	int last_hat_y;		/* last reported ABS_HAT0Y, for edge detection */

	/* Start/Select <-> HOME/BACK swap */
	bool swap_start_home;
	bool swap_available;	/* false if any of the 4 buttons missing */
	int swap_indices[4];	/* gpio_btns[] indices: START, SELECT, MODE, HAPPY1 */

	/* Virtual mouse mode (L3+R3 chord toggle) */
	struct input_dev *mouse_dev;
	bool mouse_mode;
	bool scroll_active;
	ktime_t l3_down_time;
	ktime_t r3_down_time;

	/* GPIO index for L3/R3 (set during probe) */
	int gpio_idx_l3;
	int gpio_idx_r3;
};

static const char * const stick_chan_names[NUM_STICK_CHANS] = {
	"button0", "button1", "button2", "button3",
};

static const char * const trig_chan_names[NUM_TRIG_CHANS] = {
	"l2-abs", "r2-abs",
};

/* ADC button channel names (same order as io-channel-names in DTS) */
static const char * const adc_btn_chan_names[NUM_ADC_BTNS] = {
	"left-key", "right-key", "down-key", "b-key", "x-key", "y-key",
};

/* Base axis ABS codes for sticks (before XY swap) */
static const unsigned int stick_abs_codes[NUM_STICK_CHANS] = {
	ABS_X, ABS_Y, ABS_RX, ABS_RY,
};

/* Axis ABS codes for triggers.
 *
 * V160: changed from ABS_HAT2Y/ABS_HAT2X to ABS_Z/ABS_BRAKE (0x02/0x05)
 * to match a real Xbox 360 pad's axis set. GTA:SA profiles gate on
 * motion range axis codes — ABS_Z/ABS_BRAKE enables the full Xbox 360
 * profile (including SELECT→camera binding). */
static const unsigned int trig_abs_codes[NUM_TRIG_CHANS] = {
	ABS_GAS, ABS_BRAKE,
};

/*
 * Return the ABS code for stick channel @i, accounting for XY swap.
 */
static unsigned int rk3562_stick_code(struct rk3562_joystick *joy, int i)
{
	switch (i) {
	case 0: /* LX */
		return joy->l_xy_swap ? ABS_Y : ABS_X;
	case 1: /* LY */
		return joy->l_xy_swap ? ABS_X : ABS_Y;
	case 2: /* RX */
		return joy->r_xy_swap ? ABS_RY : ABS_RX;
	case 3: /* RY */
		return joy->r_xy_swap ? ABS_RX : ABS_RY;
	default:
		return stick_abs_codes[i];
	}
}

/*
 * Whether the value reported on @code has to be negated.
 * "left-stick-invert" is the legacy both-axes flag and stays runtime
 * switchable through sysfs; invert-x/-y/-rx/-ry are per-axis DT flags for
 * boards whose stick modules are mounted rotated by 90 degrees, where one
 * axis ends up wired with the opposite polarity from the other.
 */
static bool rk3562_invert_axis(struct rk3562_joystick *joy, unsigned int code)
{
	if (joy->left_stick_invert && (code == ABS_X || code == ABS_Y))
		return true;

	switch (code) {
	case ABS_X:  return joy->inv_absx;
	case ABS_Y:  return joy->inv_absy;
	case ABS_RX: return joy->inv_abtrx;
	case ABS_RY: return joy->inv_abtry;
	default:     return false;
	}
}

/*
 * Map a raw microvolt ADC reading to the [-32767, 32767] axis range.
 * Values within the per-axis dead zone map to 0.
 */
static int rk3562_map_stick(struct rk3562_joystick *joy, int uv, int axis)
{
	int dz_lo = joy->axis_dz_lo_uv[axis];
	int dz_hi = joy->axis_dz_hi_uv[axis];
	int val;

	/* Clamp to calibration range */
	if (uv < joy->axis_min_uv)
		uv = joy->axis_min_uv;
	if (uv > joy->axis_max_uv)
		uv = joy->axis_max_uv;

	/* Dead zone -> 0 */
	if (uv >= dz_lo && uv <= dz_hi)
		return 0;

	if (uv < dz_lo) {
		/* Below dead zone: map [min, dz_lo] -> [+32767, 0]
		 * Right stick: low voltage = right/down (positive).
		 * Left stick pots may be wired with opposite polarity;
		 * corrected by per-axis negation in the poll function
		 * when left_stick_invert is set. */
		val = (int)((long long)(dz_lo - uv) * 32767 /
			    (dz_lo - joy->axis_min_uv));
	} else {
		/* Above dead zone: map [dz_hi, max] -> [0, -32767] */
		val = (int)((long long)(dz_hi - uv) * 32767 /
			    (joy->axis_max_uv - dz_hi));
	}

	if (val < AXIS_MIN)
		val = AXIS_MIN;
	if (val > AXIS_MAX)
		val = AXIS_MAX;

	return val;
}

/*
 * Map a raw microvolt reading to the [0, 32767] trigger range.
 * Uses per-trigger resting voltage as the max.
 */
static int rk3562_map_trigger(struct rk3562_joystick *joy, int uv, int trig)
{
	int trig_max = joy->trig_max_uv[trig];
	int val;

	if (uv < joy->trig_min_uv)
		uv = joy->trig_min_uv;
	if (uv > trig_max)
		uv = trig_max;

	/* Triggers are pull-up: high voltage = released, low = pressed */
	val = (int)((long long)(trig_max - uv) * 255 /
		    (trig_max - joy->trig_min_uv));

	/* Suppress noise near rest position */
	if (val < TRIG_DZ_OUTPUT)
		val = 0;

	if (val < TRIG_MIN)
		val = TRIG_MIN;
	if (val > TRIG_MAX)
		val = TRIG_MAX;

	return val;
}

/* --- IRQ-driven GPIO buttons --- */

static void rk3562_gpio_work_func(struct work_struct *work)
{
	struct rk3562_gpio_btn *btn =
		container_of(work, struct rk3562_gpio_btn, work.work);
	struct rk3562_joystick *joy = btn->joy;
	int val, idx = btn->index;

	val = gpiod_get_value_cansleep(btn->gpiod);
	if (val < 0) {
		dev_err_ratelimited(joy->dev,
				    "GPIO read failed for btn %u: %d\n",
				    btn->code, val);
		return;
	}

	/* Debug: log every button edge so we can verify L3/R3 indices from uart */

	/*
	 * SDL's GameController API resolves left/righttrigger to the ABS_Z/ABS_RZ
	 * axes and never surfaces BTN_TL2/BTN_TR2, so on boards where the
	 * shoulders are plain GPIO switches -- no SARADC trigger channel to drive
	 * those axes -- L2/R2 are invisible to PPSSPP and every other
	 * controller-API consumer.  Drive the axes from the switch instead.
	 */
	if (!joy->num_trig) {
		if (btn->code == BTN_TL2)
			input_report_abs(joy->input, ABS_Z,
					 val ? TRIG_MAX : TRIG_MIN);
		else if (btn->code == BTN_TR2)
			input_report_abs(joy->input, ABS_RZ,
					 val ? TRIG_MAX : TRIG_MIN);
	}

	dev_info(joy->dev, "btn idx=%d code=0x%x %s\n",
		 idx, btn->code, val ? "PRESS" : "REL");

	/* Track physical D-pad button states for the hat axis (V148).
	 *
	 * All four directions are GPIO on this board (dmesg shows idx=8..11 as
	 * "btn idx=" from this function, i.e. IRQ-driven), so none of them ever
	 * reach the ADC-button loop in rk3562_poll().  V149 already routed UP
	 * through joy->dpad_up so the hat axis -- not the BTN_DPAD_UP key --
	 * carries the direction.  LEFT/RIGHT/DOWN were left on the
	 * input_report_key() path, but BTN_DPAD_LEFT/RIGHT/DOWN are not in the
	 * device's KEY capability bitmap (input3/capabilities/key stops at
	 * word 7, i.e. max keycode 511), so the input core drops those events
	 * and only UP ever reached userspace.  Route all four through the hat
	 * axis, which has the sole reliable mapping (Generic.kl: axis 0x10
	 * HAT_X, axis 0x11 HAT_Y). */
	switch (btn->code) {
	case BTN_DPAD_UP:
		joy->dpad_up = val;
		break;
	case BTN_DPAD_DOWN:
		joy->dpad_down = val;
		break;
	case BTN_DPAD_LEFT:
		joy->dpad_left = val;
		break;
	case BTN_DPAD_RIGHT:
		joy->dpad_right = val;
		break;
	default:
		/* Emit normal event for non-chord, non-mouse GPIO buttons */
		input_report_key(joy->input, btn->code, val);
		break;
	}

	/*
	 * Publish the hat axes right now instead of waiting for the next poll
	 * tick: rk3562_poll() also drives hat_x/hat_y, and with a slow poll
	 * period a direction holds for only a few ms it can be overwritten
	 * before it is ever reported.
	 */
	if (btn->code == BTN_DPAD_UP || btn->code == BTN_DPAD_DOWN ||
	    btn->code == BTN_DPAD_LEFT || btn->code == BTN_DPAD_RIGHT) {
		int hat_x = 0, hat_y = 0;

		if (joy->dpad_left)  hat_x = -1;
		if (joy->dpad_right) hat_x =  1;
		if (joy->dpad_up)    hat_y = -1;
		if (joy->dpad_down)  hat_y =  1;

		input_report_abs(joy->input, ABS_HAT0X, hat_x);
		input_report_abs(joy->input, ABS_HAT0Y, hat_y);
		joy->last_hat_x = hat_x;
		joy->last_hat_y = hat_y;
	}

	input_sync(joy->input);
}

static irqreturn_t rk3562_gpio_isr(int irq, void *data)
{
	struct rk3562_gpio_btn *btn = data;
	struct rk3562_joystick *joy = btn->joy;

	mod_delayed_work(system_wq, &btn->work,
			 msecs_to_jiffies(joy->debounce_ms));

	return IRQ_HANDLED;
}

static void rk3562_cancel_gpio_work(void *data)
{
	struct rk3562_joystick *joy = data;
	int i;

	for (i = 0; i < joy->num_gpio_btns; i++)
		cancel_delayed_work_sync(&joy->gpio_btns[i].work);
}

/* --- Force feedback (rumble) --- */

static int rk3562_play_effect(struct input_dev *dev, void *data,
			      struct ff_effect *effect)
{
	struct rk3562_joystick *joy = input_get_drvdata(dev);
	bool on;

	on = effect->u.rumble.strong_magnitude ||
	     effect->u.rumble.weak_magnitude;

	joy->rumble_on = on;

	if (joy->moto_gpio)
		gpiod_set_value_cansleep(joy->moto_gpio, on);
	if (joy->moto_r_gpio)
		gpiod_set_value_cansleep(joy->moto_r_gpio, on);

	return 0;
}

/* --- Axis-to-dpad sysfs --- */

static ssize_t axis_to_dpad_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));

	return sysfs_emit(buf, "%d\n", joy->axis_to_dpad);
}

static ssize_t axis_to_dpad_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));
	bool val;
	int ret;

	ret = kstrtobool(buf, &val);
	if (ret)
		return ret;

	if (joy->axis_to_dpad && !val) {
		/* Releasing dpad buttons when disabling mode */
		if (joy->last_dpad_up) {
			input_report_key(joy->input, BTN_DPAD_UP, 0);
			joy->last_dpad_up = false;
		}
		if (joy->last_dpad_down) {
			input_report_key(joy->input, BTN_DPAD_DOWN, 0);
			joy->last_dpad_down = false;
		}
		if (joy->last_dpad_left) {
			input_report_key(joy->input, BTN_DPAD_LEFT, 0);
			joy->last_dpad_left = false;
		}
		if (joy->last_dpad_right) {
			input_report_key(joy->input, BTN_DPAD_RIGHT, 0);
			joy->last_dpad_right = false;
		}
		input_sync(joy->input);
	}

	joy->axis_to_dpad = val;

	return count;
}

static DEVICE_ATTR_RW(axis_to_dpad);

/* --- Start/Select <-> HOME/BACK swap sysfs --- */

static ssize_t swap_start_home_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));

	return sysfs_emit(buf, "%d\n", joy->swap_start_home);
}

static ssize_t swap_start_home_store(struct device *dev,
				     struct device_attribute *attr,
				     const char *buf, size_t count)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));
	bool val;
	int ret;

	ret = kstrtobool(buf, &val);
	if (ret)
		return ret;

	if (!joy->swap_available)
		return -ENODEV;

	if (val != joy->swap_start_home) {
		/* Pairwise swap: START↔BACK, SELECT↔HOME/FN */
		joy->gpio_btns[joy->swap_indices[0]].code =
			val ? BTN_TRIGGER_HAPPY1 : BTN_START;     /* START → BACK */
		joy->gpio_btns[joy->swap_indices[1]].code =
			val ? BTN_MODE : BTN_SELECT;   /* SELECT → HOME/FN */
		joy->gpio_btns[joy->swap_indices[2]].code =
			val ? BTN_SELECT : BTN_MODE;   /* HOME/FN → SELECT */
		joy->gpio_btns[joy->swap_indices[3]].code =
			val ? BTN_START : BTN_TRIGGER_HAPPY1;     /* BACK → START */
		joy->swap_start_home = val;
	}

	return count;
}

static DEVICE_ATTR_RW(swap_start_home);

/* --- Left stick inversion sysfs --- */

static ssize_t left_stick_invert_show(struct device *dev,
				      struct device_attribute *attr, char *buf)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));

	return sysfs_emit(buf, "%d\n", joy->left_stick_invert);
}

static ssize_t left_stick_invert_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	struct rk3562_joystick *joy = platform_get_drvdata(to_platform_device(dev));
	bool val;
	int ret;

	ret = kstrtobool(buf, &val);
	if (ret)
		return ret;

	joy->left_stick_invert = val;

	return count;
}

static DEVICE_ATTR_RW(left_stick_invert);

static struct attribute *rk3562_attrs[] = {
	&dev_attr_axis_to_dpad.attr,
	&dev_attr_swap_start_home.attr,
	&dev_attr_left_stick_invert.attr,
	NULL,
};
ATTRIBUTE_GROUPS(rk3562);

/* --- Poll function --- */

static void rk3562_poll(struct input_dev *input)
{
	struct rk3562_joystick *joy = input_get_drvdata(input);
	int stick_vals[NUM_STICK_CHANS];
	int i, ret, raw;

	/* Step 1: Read all stick channels */
	for (i = 0; i < NUM_STICK_CHANS; i++) {
		ret = iio_read_channel_processed(joy->stick_chans[i], &raw);
		if (ret < 0) {
			dev_warn_once(joy->dev,
				      "Stick %d (%s): IIO read failed: %d\n",
				      i, stick_chan_names[i], ret);
			stick_vals[i] = 0;
			continue;
		}

		/* iio_read_channel_processed returns millivolts; convert to uV */
		raw *= 1000;

		stick_vals[i] = rk3562_map_stick(joy, raw, i);
	}

	/* Step 2: Read and report triggers */
	for (i = 0; i < joy->num_trig; i++) {
		ret = iio_read_channel_processed(joy->trig_chans[i], &raw);
		if (ret < 0)
			continue;

		raw *= 1000;
		input_report_abs(input, trig_abs_codes[i],
				 rk3562_map_trigger(joy, raw, i));
	}

	/* Step 3: Read and report ADC-threshold buttons */
	for (i = 0; i < joy->num_adc_btn; i++) {
		ret = iio_read_channel_processed(joy->adc_btn_chans[i], &raw);
		if (ret < 0)
			continue;

	{
		int pressed;

		raw *= 1000; /* mV -> uV */
		pressed = (raw < joy->adc_btn_thresh[i]);

		/* Track physical D-pad direction states for hat axis (V148).
		 * V149: suppress BTN_DPAD_* key events for the D-pad channels so
		 * the hat axis is the sole D-pad source (no UI double-step).
		 * Non-dpad ADC buttons (b/x/y) still report normally. */
		if (joy->adc_btn_codes[i] == BTN_DPAD_LEFT)
			joy->dpad_left = pressed;
		else if (joy->adc_btn_codes[i] == BTN_DPAD_RIGHT)
			joy->dpad_right = pressed;
		else if (joy->adc_btn_codes[i] == BTN_DPAD_DOWN)
			joy->dpad_down = pressed;
		else
			input_report_key(input, joy->adc_btn_codes[i], pressed);
	}
	}

	/* Step 4: GPIO buttons handled by IRQs, not polled */

	/* Step 5/6: Report stick axes or dpad */
	if (joy->axis_to_dpad) {
		int log_x = 0, log_y = 0;
		bool up, down, left, right;

		for (i = 0; i < 2; i++) {
			int val = stick_vals[i];
			unsigned int code = rk3562_stick_code(joy, i);

			if (rk3562_invert_axis(joy, code))
				val = -val;

			if (code == ABS_X)
				log_x = val;
			else
				log_y = val;
		}

		up    = log_y < -DPAD_THRESHOLD;
		down  = log_y >  DPAD_THRESHOLD;
		left  = log_x < -DPAD_THRESHOLD;
		right = log_x >  DPAD_THRESHOLD;

		if (up != joy->last_dpad_up) {
			input_report_key(input, BTN_DPAD_UP, up);
			joy->last_dpad_up = up;
		}
		if (down != joy->last_dpad_down) {
			input_report_key(input, BTN_DPAD_DOWN, down);
			joy->last_dpad_down = down;
		}
		if (left != joy->last_dpad_left) {
			input_report_key(input, BTN_DPAD_LEFT, left);
			joy->last_dpad_left = left;
		}
		if (right != joy->last_dpad_right) {
			input_report_key(input, BTN_DPAD_RIGHT, right);
			joy->last_dpad_right = right;
		}

		/* Still report left stick as zeroed ABS so apps don't see stale values */
		input_report_abs(input, rk3562_stick_code(joy, 0), 0);
		input_report_abs(input, rk3562_stick_code(joy, 1), 0);

		/* Right stick still reports normally */
		input_report_abs(input, rk3562_stick_code(joy, 2), stick_vals[2]);
		input_report_abs(input, rk3562_stick_code(joy, 3), stick_vals[3]);
	} else {
		/* Normal mode: report all 4 axes with XY swap */
		for (i = 0; i < NUM_STICK_CHANS; i++) {
			int val = stick_vals[i];
			unsigned int code = rk3562_stick_code(joy, i);

			/* If left stick inversion is enabled, negate both
			 * left axes.  This corrects for devices where the
			 * left stick module is physically rotated 180
			 * degrees (ribbon cable faces inward), giving
			 * opposite voltage polarity from the right stick. */
			if (rk3562_invert_axis(joy, code))
				val = -val;

			input_report_abs(input, code, val);
		}
	}

	/* Report D-pad hat axes from PHYSICAL D-pad buttons (V148).
	 * UP=GPIO, LEFT/RIGHT/DOWN=ADC.  Left stick stays pure analog. */
	{
		int hat_x = 0, hat_y = 0;

		if (joy->dpad_left)  hat_x = -1;
		if (joy->dpad_right) hat_x =  1;
		if (joy->dpad_up)    hat_y = -1; /* ABS_HAT0Y: -1=up (Android) */
		if (joy->dpad_down)  hat_y =  1; /* ABS_HAT0Y: +1=down */

		/* Only report on change: rk3562_gpio_work_func() already publishes
		 * the hat immediately on a GPIO D-pad edge, so re-reporting the same
		 * value every poll tick would flood the input queue. */
		if (hat_x != joy->last_hat_x || hat_y != joy->last_hat_y) {
			input_report_abs(input, ABS_HAT0X, hat_x);
			input_report_abs(input, ABS_HAT0Y, hat_y);
			joy->last_hat_x = hat_x;
			joy->last_hat_y = hat_y;
		}
	}

	/* Step 7: Single sync */
	input_sync(input);
	if (joy->mouse_dev)
		input_sync(joy->mouse_dev);
}

/* --- Auto-calibration --- */

/*
 * Read an IIO channel @samples times and return the average in millivolts.
 * Discards the first reading as a warm-up. Returns negative on error.
 */
static int rk3562_read_avg(struct iio_channel *chan, int samples)
{
	int i, ret, val;
	long sum = 0;
	int count = 0;

	/* Warm-up read (discarded) */
	ret = iio_read_channel_processed(chan, &val);
	if (ret < 0)
		return ret;
	udelay(CALIBRATION_DELAY_US);

	for (i = 0; i < samples; i++) {
		ret = iio_read_channel_processed(chan, &val);
		if (ret < 0)
			return ret;
		sum += val;
		count++;
		if (i < samples - 1)
			udelay(CALIBRATION_DELAY_US);
	}

	return (int)(sum / count);  /* millivolts */
}

/*
 * Calibrate stick dead zones and trigger max values by reading ADC channels
 * at rest (nothing pressed). Must be called after IIO channels are acquired
 * and before input device registration.
 */
static void rk3562_calibrate(struct rk3562_joystick *joy)
{
	struct device *dev = joy->dev;
	int i, center_mv, rest_mv;

	/* Calibrate stick dead zones */
	for (i = 0; i < NUM_STICK_CHANS; i++) {
		static const char * const axis_labels[] = {
			"LX", "LY", "RX", "RY"
		};

		center_mv = rk3562_read_avg(joy->stick_chans[i],
					    CALIBRATION_SAMPLES);
		if (center_mv < 0) {
			dev_warn(dev, "Stick %d (%s/%s): calibration read failed (%d), using DT defaults\n",
				 i, axis_labels[i], stick_chan_names[i],
				 center_mv);
			continue;
		}

		/* Validate: center should be well within the physical range */
		if (center_mv * 1000 < joy->axis_min_uv + 200000 ||
		    center_mv * 1000 > joy->axis_max_uv - 200000) {
			dev_warn(dev, "Stick %d (%s/%s): center %d mV outside safe range [%d, %d] mV, using DT defaults\n",
				 i, axis_labels[i], stick_chan_names[i],
				 center_mv,
				 (joy->axis_min_uv + 200000) / 1000,
				 (joy->axis_max_uv - 200000) / 1000);
			continue;
		}

		joy->axis_dz_lo_uv[i] = center_mv * 1000 - STICK_DZ_MARGIN_UV;
		joy->axis_dz_hi_uv[i] = center_mv * 1000 + STICK_DZ_MARGIN_UV;

		dev_info(dev, "Stick %d (%s/%s): center %d mV, dead zone [%d, %d] mV\n",
			 i, axis_labels[i], stick_chan_names[i],
			 center_mv,
			 joy->axis_dz_lo_uv[i] / 1000,
			 joy->axis_dz_hi_uv[i] / 1000);
	}

	/* Calibrate trigger resting voltages */
	for (i = 0; i < joy->num_trig; i++) {
		rest_mv = rk3562_read_avg(joy->trig_chans[i],
					  CALIBRATION_SAMPLES);
		if (rest_mv < 0) {
			dev_warn(dev, "Trigger %d: calibration read failed (%d), using DT default\n",
				 i, rest_mv);
			continue;
		}

		/* Validate: rest voltage should be reasonably high (trigger not stuck) */
		if (rest_mv < 400) {
			dev_warn(dev, "Trigger %d: rest %d mV too low (stuck/pressed at boot?), using DT default\n",
				 i, rest_mv);
			continue;
		}

		joy->trig_max_uv[i] = rest_mv * 1000;

		dev_info(dev, "Trigger %d: rest %d mV\n", i, rest_mv);
	}
}

/* --- DT parsing --- */

static int rk3562_parse_adc_buttons(struct rk3562_joystick *joy,
				    struct device *dev)
{
	struct device_node *node = dev->of_node;
	struct device_node *child;
	int i = 0;

	for_each_child_of_node(node, child) {
		u32 code, thresh;

		if (i >= NUM_ADC_BTNS) {
			of_node_put(child);
			break;
		}

		if (of_property_read_u32(child, "linux,code", &code)) {
			dev_warn(dev, "ADC button %s missing linux,code\n",
				 child->name);
			continue;
		}

		if (of_property_read_u32(child, "press-threshold-microvolt",
					 &thresh))
			thresh = 80000; /* default 80 mV */

		joy->adc_btn_codes[i] = code;
		joy->adc_btn_thresh[i] = thresh;
		i++;
	}

	/* Report only as many ADC buttons as both a channel and a child node */
	if (i < joy->num_adc_btn)
		joy->num_adc_btn = i;

	return 0;
}

/*
 * Remap DTS key codes that fall outside the BTN_* range (and would be
 * invisible to joydev) into joydev-visible BTN_* codes.
 *
 * KEY_HOME -> BTN_MODE (the SDL Guide button).
 * KEY_FN   -> BTN_TRIGGER_HAPPY1: a generic "extra button" slot in the
 *             BTN_TRIGGER_HAPPY1..40 range (evdev 0x2c0..0x2e7) that the
 *             kernel input subsystem reserves for buttons that don't fit
 *             the standard gamepad layout.  Avoids overloading BTN_TL2
 *             (the canonical Left Trigger 2 code) for an unrelated
 *             function button.
 */
static unsigned int rk3562_remap_code(unsigned int dts_code)
{
	switch (dts_code) {
	case KEY_HOME_DTS:
		return BTN_MODE;            /* 0x13c -- HOME -> Guide */
	case KEY_FN_DTS:
		return BTN_TRIGGER_HAPPY1;  /* 0x2c0 -- FN/BACK -> extra btn */
	default:
		return dts_code;
	}
}

/* --- PM ops --- */

static int rk3562_suspend(struct device *dev)
{
	struct rk3562_joystick *joy = dev_get_drvdata(dev);

	/* Turn off motors on suspend */
	if (joy->moto_gpio)
		gpiod_set_value_cansleep(joy->moto_gpio, 0);
	if (joy->moto_r_gpio)
		gpiod_set_value_cansleep(joy->moto_r_gpio, 0);

	return 0;
}

static int rk3562_resume(struct device *dev)
{
	struct rk3562_joystick *joy = dev_get_drvdata(dev);

	/* Restore rumble state */
	if (joy->rumble_on) {
		if (joy->moto_gpio)
			gpiod_set_value_cansleep(joy->moto_gpio, 1);
		if (joy->moto_r_gpio)
			gpiod_set_value_cansleep(joy->moto_r_gpio, 1);
	}

	return 0;
}

static SIMPLE_DEV_PM_OPS(rk3562_pm_ops, rk3562_suspend, rk3562_resume);

/*
 * Acquire an IIO channel by name, treating channels this board does not wire
 * up as absent instead of as probe failures.  Returns NULL when the name is
 * not listed in io-channel-names, and bumps *count on success.
 */
static struct iio_channel *rk3562_get_named_channel(struct device *dev,
						   const char *name, int *count)
{
	struct iio_channel *chan;

	if (of_property_match_string(dev->of_node, "io-channel-names", name) < 0)
		return NULL;

	chan = devm_iio_channel_get(dev, name);
	if (IS_ERR(chan))
		return chan;

	(*count)++;
	return chan;
}

/* --- Probe --- */

static int rk3562_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct rk3562_joystick *joy;
	struct input_dev *input;
	u32 *gpio_codes;
	u32 poll_interval = 8;
	u32 debounce_ms = DEFAULT_DEBOUNCE_MS;
	int axis_min_mv, axis_max_mv, dz_lo_mv, dz_hi_mv;
	int trig_min_mv, trig_max_mv;
	int i, ret, count;

	joy = devm_kzalloc(dev, sizeof(*joy), GFP_KERNEL);
	if (!joy)
		return -ENOMEM;

	joy->dev = dev;
	platform_set_drvdata(pdev, joy);

	/* --- Parse DT properties --- */

	of_property_read_u32(dev->of_node, "poll-interval", &poll_interval);
	/* Ignore DT debounce-interval (100ms) -- manufacturer's own driver
	 * hardcoded 10ms instead of using it. 5ms is correct for silicone-
	 * dampened microswitches. */
	joy->debounce_ms = debounce_ms;

	/* Axis X/Y swap */
	joy->l_xy_swap = of_property_read_bool(dev->of_node, "l_xy_swap");
	joy->r_xy_swap = of_property_read_bool(dev->of_node, "r_xy_swap");

	/* Left stick polarity inversion.  Set this in DT for devices where
	 * the left stick module is physically rotated 180 degrees, giving
	 * opposite voltage polarity from the right stick. */
	joy->left_stick_invert = of_property_read_bool(dev->of_node,
						       "left-stick-invert");

	/* Per-axis polarity inversion */
	joy->inv_absx = of_property_read_bool(dev->of_node, "invert-x");
	joy->inv_absy = of_property_read_bool(dev->of_node, "invert-y");
	joy->inv_abtrx = of_property_read_bool(dev->of_node, "invert-rx");
	joy->inv_abtry = of_property_read_bool(dev->of_node, "invert-ry");

	/* Stick calibration (millivolts -> microvolts) */
	if (of_property_read_u32(dev->of_node, "axis-min-value-mv",
				 &axis_min_mv))
		axis_min_mv = 250;
	if (of_property_read_u32(dev->of_node, "axis-max-value-mv",
				 &axis_max_mv))
		axis_max_mv = 1550;
	if (of_property_read_u32(dev->of_node, "axis-dead-zone-l", &dz_lo_mv))
		dz_lo_mv = 790;
	if (of_property_read_u32(dev->of_node, "axis-dead-zone-h", &dz_hi_mv))
		dz_hi_mv = 1010;

	joy->axis_min_uv = axis_min_mv * 1000;
	joy->axis_max_uv = axis_max_mv * 1000;
	/* Set DT dead zone as default for all axes (calibration overwrites) */
	for (i = 0; i < NUM_STICK_CHANS; i++) {
		joy->axis_dz_lo_uv[i] = dz_lo_mv * 1000;
		joy->axis_dz_hi_uv[i] = dz_hi_mv * 1000;
	}

	/* Trigger calibration */
	if (of_property_read_u32(dev->of_node, "l2-r2-min-value-mv",
				 &trig_min_mv))
		trig_min_mv = 50;
	if (of_property_read_u32(dev->of_node, "l2-r2-max-value-mv",
				 &trig_max_mv))
		trig_max_mv = 800;

	joy->trig_min_uv = TRIG_MIN_UV;
	/* Set DT max as default for both triggers (calibration overwrites) */
	for (i = 0; i < NUM_TRIG_CHANS; i++)
		joy->trig_max_uv[i] = trig_max_mv * 1000;

	/* --- Acquire IIO channels --- */

	for (i = 0; i < NUM_STICK_CHANS; i++) {
		joy->stick_chans[i] = devm_iio_channel_get(dev,
							    stick_chan_names[i]);
		if (IS_ERR(joy->stick_chans[i])) {
			ret = PTR_ERR(joy->stick_chans[i]);
			if (ret != -EPROBE_DEFER)
				dev_err(dev, "Failed to get IIO channel %s: %d\n",
					stick_chan_names[i], ret);
			return ret;
		}
	}

	for (i = 0; i < NUM_TRIG_CHANS; i++) {
		joy->trig_chans[i] = rk3562_get_named_channel(dev,
					trig_chan_names[i], &joy->num_trig);
		if (IS_ERR(joy->trig_chans[i])) {
			ret = PTR_ERR(joy->trig_chans[i]);
			dev_err(dev, "Failed to get IIO channel %s: %d\n",
				trig_chan_names[i], ret);
			return ret;
		}
	}

	for (i = 0; i < NUM_ADC_BTNS; i++) {
		joy->adc_btn_chans[i] = rk3562_get_named_channel(dev,
					adc_btn_chan_names[i], &joy->num_adc_btn);
		if (IS_ERR(joy->adc_btn_chans[i])) {
			ret = PTR_ERR(joy->adc_btn_chans[i]);
			dev_err(dev, "Failed to get IIO channel %s: %d\n",
				adc_btn_chan_names[i], ret);
			return ret;
		}
	}

	/* --- Auto-calibrate sticks and triggers from ADC at rest --- */

	rk3562_calibrate(joy);

	/* --- Parse ADC button child nodes --- */

	ret = rk3562_parse_adc_buttons(joy, dev);
	if (ret)
		return ret;

	/* --- Acquire GPIO buttons (IRQ-driven) --- */

	count = of_property_count_u32_elems(dev->of_node, "key-gpios-map");
	if (count <= 0) {
		dev_err(dev, "Missing or empty key-gpios-map property\n");
		return -EINVAL;
	}

	joy->num_gpio_btns = count;
	joy->gpio_btns = devm_kcalloc(dev, count, sizeof(*joy->gpio_btns),
				      GFP_KERNEL);
	if (!joy->gpio_btns)
		return -ENOMEM;

	gpio_codes = devm_kcalloc(dev, count, sizeof(*gpio_codes), GFP_KERNEL);
	if (!gpio_codes)
		return -ENOMEM;

	ret = of_property_read_u32_array(dev->of_node, "key-gpios-map",
					 gpio_codes, count);
	if (ret) {
		dev_err(dev, "Failed to read key-gpios-map: %d\n", ret);
		return ret;
	}

	for (i = 0; i < count; i++) {
		struct rk3562_gpio_btn *btn = &joy->gpio_btns[i];

		btn->joy = joy;
		btn->index = i;
		btn->code = rk3562_remap_code(gpio_codes[i]);
		INIT_DELAYED_WORK(&btn->work, rk3562_gpio_work_func);

		btn->gpiod = devm_gpiod_get_index(dev, "key", i, GPIOD_IN);
		if (IS_ERR(btn->gpiod)) {
			ret = PTR_ERR(btn->gpiod);
			if (ret != -EPROBE_DEFER)
				dev_err(dev, "Failed to get GPIO %d: %d\n",
					i, ret);
			return ret;
		}

		btn->irq = gpiod_to_irq(btn->gpiod);
		if (btn->irq < 0) {
			dev_err(dev, "Failed to get IRQ for GPIO %d: %d\n",
				i, btn->irq);
			return btn->irq;
		}

		ret = devm_request_any_context_irq(dev, btn->irq,
						   rk3562_gpio_isr,
						   IRQF_TRIGGER_RISING |
						   IRQF_TRIGGER_FALLING,
						   DRIVER_NAME, btn);
		if (ret < 0) {
			dev_err(dev, "Failed to request IRQ %d for GPIO %d: %d\n",
				btn->irq, i, ret);
			return ret;
		}
	}

	ret = devm_add_action_or_reset(dev, rk3562_cancel_gpio_work, joy);
	if (ret)
		return ret;

	/* --- Locate swappable buttons for Start/Select <-> HOME/BACK --- */
	{
		static const unsigned int swap_codes[4] = {
			BTN_START, BTN_SELECT, BTN_MODE, BTN_TRIGGER_HAPPY1,
		};
		int found = 0;

		for (i = 0; i < 4; i++)
			joy->swap_indices[i] = -1;

		for (i = 0; i < joy->num_gpio_btns; i++) {
			int j;

			for (j = 0; j < 4; j++) {
				if (joy->gpio_btns[i].code == swap_codes[j]) {
					joy->swap_indices[j] = i;
					found++;
					break;
				}
			}
		}

		joy->swap_available = (found == 4);
		if (joy->swap_available)
			dev_info(dev, "Button swap available (START=%d SELECT=%d MODE=%d HAPPY1=%d)\n",
				 joy->swap_indices[0], joy->swap_indices[1],
				 joy->swap_indices[2], joy->swap_indices[3]);
		else
			dev_info(dev, "Button swap not available (found %d/4 buttons)\n",
				 found);
	}

	/* --- Acquire rumble motor GPIOs (optional) --- */

	joy->moto_gpio = devm_gpiod_get_optional(dev, "moto", GPIOD_OUT_LOW);
	if (IS_ERR(joy->moto_gpio))
		return dev_err_probe(dev, PTR_ERR(joy->moto_gpio),
				     "Failed to get moto GPIO\n");

	joy->moto_r_gpio = devm_gpiod_get_optional(dev, "moto-r",
						    GPIOD_OUT_LOW);
	if (IS_ERR(joy->moto_r_gpio))
		return dev_err_probe(dev, PTR_ERR(joy->moto_r_gpio),
				     "Failed to get moto-r GPIO\n");

	/* --- Setup input device --- */

	input = devm_input_allocate_device(dev);
	if (!input)
		return -ENOMEM;

	joy->input = input;
	input->name = "retrogame_joypad";
	input->phys = "retrogame_joypad/input0";
	input->id.bustype = BUS_BLUETOOTH;
	input->id.vendor = 0x045e;   /* Microsoft */
	input->id.product = 0x0b13;  /* Xbox Series X|S controller (BLE) */
	input->id.version = 0x0515;

	input_set_drvdata(input, joy);

	/* Register stick axes (widen flat to 256 to stop centered-stick MOVE flood) */
	for (i = 0; i < NUM_STICK_CHANS; i++) {
		input_set_abs_params(input, stick_abs_codes[i],
				     AXIS_MIN, AXIS_MAX, 16, 256);
	}

	/* Register trigger axes (V160: 0..255 to match Xbox 360 pad).
	 *
	 * NGP45HT: boards without analog shoulders (L2/R2 on plain GPIO) still
	 * get ABS_Z/ABS_RZ advertised, just never driven, so joydev hands out
	 * the same axis indices on every RK3562 device:
	 * 0=LX 1=LY 2=L2 3=RX 4=RY 5=R2. */
	for (i = 0; i < NUM_TRIG_CHANS; i++) {
		input_set_abs_params(input, trig_abs_codes[i],
				     0, 255, 0, 0);
	}

	/* Register D-pad hat axes (Strategy C1: BTN_DPAD keys kept alongside) */
	input_set_capability(input, EV_ABS, ABS_HAT0X);
	input_set_capability(input, EV_ABS, ABS_HAT0Y);
	input_set_abs_params(input, ABS_HAT0X, -1, 1, 0, 0);
	input_set_abs_params(input, ABS_HAT0Y, -1, 1, 0, 0);

	/* Register GPIO buttons */
	for (i = 0; i < joy->num_gpio_btns; i++)
		input_set_capability(input, EV_KEY, joy->gpio_btns[i].code);

	/* Register ADC buttons */
	for (i = 0; i < joy->num_adc_btn; i++)
		input_set_capability(input, EV_KEY, joy->adc_btn_codes[i]);

	/* Register BTN_MODE so joydev places HOME/BACK after SELECT/START
	 * in the button map.  V156: BTN_TL2 and BTN_TR2 are intentionally
	 * NOT registered — omitting them shifts BTN_SELECT from joydev
	 * index 8 to index 6, matching the Microsoft X-Box 360 pad layout
	 * (GTA:SA reads buttons by joydev index). */
	input_set_capability(input, EV_KEY, BTN_MODE);

	/* Register dpad button capabilities (for axis-to-dpad mode) */
	input_set_capability(input, EV_KEY, BTN_DPAD_UP);
	input_set_capability(input, EV_KEY, BTN_DPAD_DOWN);
	input_set_capability(input, EV_KEY, BTN_DPAD_LEFT);
	input_set_capability(input, EV_KEY, BTN_DPAD_RIGHT);

	/* Setup force feedback if motors are present */
	if (joy->moto_gpio || joy->moto_r_gpio) {
		input_set_capability(input, EV_FF, FF_RUMBLE);
		ret = input_ff_create_memless(input, NULL,
					      rk3562_play_effect);
		if (ret) {
			dev_err(dev, "Failed to create FF device: %d\n", ret);
			return ret;
		}
	}

	/* Setup polling (for analog axes and ADC buttons) */
	ret = input_setup_polling(input, rk3562_poll);
	if (ret) {
		dev_err(dev, "Failed to setup polling: %d\n", ret);
		return ret;
	}

	input_set_poll_interval(input, poll_interval);
	input_set_min_poll_interval(input, 8);
	input_set_max_poll_interval(input, 100);

	ret = input_register_device(input);
	if (ret) {
		dev_err(dev, "Failed to register input device: %d\n", ret);
		return ret;
	}

	/* Create secondary input device for virtual mouse (L3+R3 chord) */
	joy->mouse_dev = devm_input_allocate_device(dev);
	if (joy->mouse_dev) {
		joy->mouse_dev->name = MOUSE_NAME;
		joy->mouse_dev->id.bustype = BUS_HOST;
		joy->mouse_dev->id.vendor = 0;
		joy->mouse_dev->id.product = 0;
		joy->mouse_dev->id.version = 0x0100;

		input_set_capability(joy->mouse_dev, EV_REL, REL_X);
		input_set_capability(joy->mouse_dev, EV_REL, REL_Y);
		input_set_capability(joy->mouse_dev, EV_REL, REL_WHEEL);
		input_set_capability(joy->mouse_dev, EV_REL, REL_HWHEEL);
		input_set_capability(joy->mouse_dev, EV_KEY, BTN_LEFT);

// DISABLED for V178: 		ret = input_register_device(joy->mouse_dev);
		if (ret) {
			dev_warn(dev, "Failed to register mouse device: %d\n",
				 ret);
			joy->mouse_dev = NULL;
		} else {
			dev_info(dev, "Virtual mouse device registered\n");
		}
	}

	/* Set L3/R3 GPIO indices (hardware-specific: GPIO[6]=L3, GPIO[7]=R3) */
	joy->gpio_idx_l3 = 8;
	joy->gpio_idx_r3 = 9;
	dev_info(dev, "L3=GPIO[%d] R3=GPIO[%d]\n", joy->gpio_idx_l3,
		 joy->gpio_idx_r3);

	dev_info(dev, "RK3562 joystick registered (%d GPIOs, poll %u ms, debounce %u ms, rumble %s, lstick-invert %s)\n",
		 joy->num_gpio_btns, poll_interval, joy->debounce_ms,
		 (joy->moto_gpio || joy->moto_r_gpio) ? "yes" : "no",
		 joy->left_stick_invert ? "yes" : "no");

	return 0;
}

static const struct of_device_id rk3562_of_match[] = {
	{ .compatible = "play_joystick" },
	{ },
};
MODULE_DEVICE_TABLE(of, rk3562_of_match);

static struct platform_driver rk3562_driver = {
	.probe = rk3562_probe,
	.driver = {
		.name = DRIVER_NAME,
		.of_match_table = rk3562_of_match,
		.pm = &rk3562_pm_ops,
		.dev_groups = rk3562_groups,
	},
};
module_platform_driver(rk3562_driver);

MODULE_DESCRIPTION("RK3562 handheld gamepad driver");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("dArkOS contributors");
