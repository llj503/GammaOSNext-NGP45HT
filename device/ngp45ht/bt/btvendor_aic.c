/*
 * libbt-vendor для AIC8800 на RG52 Mini.
 *
 * Ядро (aic8800_fdrv с CONFIG_SDIO_BT=y, ветка BlueZ) даёт обычный hci0
 * и само заливает прошивку, поэтому здесь нет ни firmware, ни питания,
 * ни UART -- нужно лишь отдать Fluoride поток H4.
 *
 * Тонкость: HAL читает дескриптор ПОТОКОВО (байт типа, затем заголовок,
 * затем тело), а HCI-сокет пакетный -- чтение одного байта отбрасывает
 * остаток датаграммы. Поэтому наружу отдаётся socketpair (SOCK_STREAM),
 * а поток-ретранслятор переносит данные между ним и HCI-сокетом,
 * собирая на передаче целые H4-пакеты по их заголовкам.
 */

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <android/log.h>

#define LOG_TAG "bt-vendor-aic"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define AF_BLUETOOTH_     31
#define BTPROTO_HCI_       1
#define HCI_CHANNEL_USER_  1
#define HCIDEVDOWN_  0x400448ca
#define HCI_DEV_ID         0

struct sockaddr_hci_ { unsigned short hci_family, hci_dev, hci_channel; };

enum {
    OP_POWER_CTRL = 0, OP_FW_CFG, OP_SCO_CFG, OP_USERIAL_OPEN,
    OP_USERIAL_CLOSE, OP_GET_LPM_IDLE_TIMEOUT, OP_LPM_SET_MODE,
    OP_LPM_WAKE_SET_STATE, OP_SET_AUDIO_STATE, OP_EPILOG,
    OP_A2DP_OFFLOAD_START, OP_A2DP_OFFLOAD_STOP
};
#define RESULT_SUCCESS 0
#define CH_MAX         4

typedef void (*cfg_result_cb)(int result);
typedef void* (*malloc_cb)(int size);
typedef void (*mdealloc_cb)(void *p);
typedef uint8_t (*cmd_xmit_cb)(uint16_t opcode, void *p_buf, void *cback);

typedef struct {
    size_t size;
    cfg_result_cb fwcfg_cb, scocfg_cb, lpm_cb, audio_state_cb;
    malloc_cb alloc; mdealloc_cb dealloc; cmd_xmit_cb xmit_cb;
    cfg_result_cb epilog_cb, a2dp_offload_cb;
} vnd_callbacks_t;

typedef struct {
    size_t size;
    int  (*init)(const vnd_callbacks_t *cb, unsigned char *local_bdaddr);
    int  (*op)(int opcode, void *param);
    void (*cleanup)(void);
} vnd_interface_t;

static const vnd_callbacks_t *g_cb;
static int g_hci = -1;      /* HCI-сокет к ядру      */
static int g_our = -1;      /* наш конец socketpair  */
static int g_hal = -1;      /* конец, отданный HAL   */
static pthread_t g_relay;
static volatile int g_run;

/* Полная длина H4-пакета по его заголовку; 0 -- данных пока мало. */
static int h4_len(const unsigned char *b, int n)
{
    if (n < 1) return 0;
    switch (b[0]) {
    case 0x01: return (n < 4) ? 0 : 4 + b[3];                    /* command */
    case 0x02: return (n < 5) ? 0 : 5 + (b[3] | (b[4] << 8));    /* ACL     */
    case 0x03: return (n < 4) ? 0 : 4 + b[3];                    /* SCO     */
    case 0x04: return (n < 3) ? 0 : 3 + b[2];                    /* event   */
    default:   return -1;                                        /* мусор   */
    }
}

static void *relay(void *unused)
{
    unsigned char tx[4096];
    int txn = 0;
    (void)unused;

    while (g_run) {
        struct pollfd p[2] = { { g_hci, POLLIN, 0 }, { g_our, POLLIN, 0 } };
        if (poll(p, 2, 500) <= 0) continue;

        /* контроллер -> HAL: пакет читаем целиком, отдаём потоком */
        if (p[0].revents & POLLIN) {
            unsigned char buf[2048];
            int n = read(g_hci, buf, sizeof buf);
            if (n > 0) {
                /* NGP45HT debug: log every controller event head */
                if (buf[0] == 0x04 && n >= 7 && buf[1] == 0x0e)
                    LOGI("EVT complete opcode=0x%04x st=0x%02x n=%d",
                         buf[4] | (buf[5] << 8), buf[6], n);
                else if (buf[0] == 0x04 && n >= 5)
                    LOGI("EVT code=0x%02x n=%d %02x %02x %02x %02x",
                         buf[1], n, buf[2], buf[3], buf[4], buf[5]);
                if (write(g_our, buf, n) != n) LOGE("write в HAL не полный");
            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                LOGE("read hci: %s", strerror(errno)); break;
            }
        }

        /* HAL -> контроллер: копим поток и шлём целыми пакетами */
        if (p[1].revents & POLLIN) {
            int n = read(g_our, tx + txn, sizeof tx - txn);
            if (n > 0) {
                txn += n;
                for (;;) {
                    int len = h4_len(tx, txn);
                    if (len < 0) { LOGE("неизвестный тип 0x%02X, сброс", tx[0]); txn = 0; break; }
                    if (len == 0 || len > txn) break;      /* ждём остаток */
                    /* NGP45HT: BootROM BT fw has no Read Local Supported
                     * Codecs V2 (0x0C6D) and the Android-14 GD stack asserts
                     * on the error.  Do not forward: answer with SUCCESS and
                     * an empty codec list instead. */
                    unsigned oc = (len >= 4 && tx[0] == 0x01)
                                  ? (tx[1] | (tx[2] << 8)) : 0;
                    if (oc == 0x0C6D) {
                        /* BootROM fw: no Codecs V2; the GD stack asserts on
                         * the error.  Answer SUCCESS + empty codec list. */
                        static const unsigned char r1[] =
                            { 0x04, 0x0e, 0x04, 0x01, 0x6d, 0x0c, 0x00 };
                        if (write(g_our, r1, sizeof r1) != (int)sizeof r1)
                            LOGE("write фейка 0C6D: %s", strerror(errno));
                        LOGI("0x0C6D перехвачен -> SUCCESS (пустой список кодеков)");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x1004) {
                        /* BootROM fw rejects Read Local Extended Features;
                         * answer: max page 0, no extended features. */
                        /* return: status + page_number + max_page + 8 features.
                         * Features double as page-0 LMP features for the stack:
                         * byte0 bit2 encryption, byte3 bit6 RSSI w/ inquiry,
                         * byte4 bit6 LE, byte5 bit3 SSP controller,
                         * byte6 bit3 SSP host (Android asserts without it),
                         * byte6 bit4 EIR. */
                        static const unsigned char r4[] = {
                            0x04, 0x0e, 0x0e, 0x01, 0x04, 0x10, 0x00,
                            0x00,               /* page number */
                            0x00,               /* max page    */
                            0x04, 0x00, 0x00, 0x40,
                            0x60, 0x08, 0x18, 0x00
                        };
                        if (write(g_our, r4, sizeof r4) != (int)sizeof r4)
                            LOGE("write фейка 1004: %s", strerror(errno));
                        LOGI("0x1004 перехвачен -> пустая страница расширенных фич");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x1003) {
                        /* BootROM reports an all-but-empty feature mask and
                         * the GD stack asserts without Simple Pairing.  Patch
                         * the real reply: set SSP (host+controller) bits and
                         * encryption; keep the rest as reported. */
                        /* [04][0e][plen][numpkt][opcode:2][status][features:8] */
                        static const unsigned char r7[] = {
                            0x04, 0x0e, 0x0c, 0x01, 0x03, 0x10, 0x00,
                            0x04,       /* byte0: encryption            */
                            0x00, 0x00, 0x00,
                            0x60,       /* byte4: keep RSSI/power ctrl  */
                            0x08,       /* byte5: SSP controller        */
                            0x08,       /* byte6: SSP host              */
                            0x00
                        };
                        if (write(g_our, r7, sizeof r7) != (int)sizeof r7)
                            LOGE("write фейка 1003: %s", strerror(errno));
                        LOGI("0x1003 перехвачен -> включены SSP+Encryption");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x080F) {
                        /* Write Default Link Policy Settings: BootROM fw
                         * rejects with 0x11; answer SUCCESS. */
                        static const unsigned char r8[] =
                            { 0x04, 0x0e, 0x04, 0x01, 0x0f, 0x08, 0x00 };
                        if (write(g_our, r8, sizeof r8) != (int)sizeof r8)
                            LOGE("write фейка 080F: %s", strerror(errno));
                        LOGI("0x080F перехвачен -> SUCCESS");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x0C56) {
                        /* Write Inquiry Mode: BootROM fw rejects; SUCCESS. */
                        static const unsigned char r9[] =
                            { 0x04, 0x0e, 0x04, 0x01, 0x56, 0x0c, 0x00 };
                        if (write(g_our, r9, sizeof r9) != (int)sizeof r9)
                            LOGE("write фейка 0C56: %s", strerror(errno));
                        LOGI("0x0C56 перехвачен -> SUCCESS");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x1005) {
                        /* BootROM fw rejects Read Buffer Size; return sane
                         * ACL/sync buffer parameters. */
                        static const unsigned char r5[] = {
                            0x04, 0x0e, 0x0b, 0x01, 0x05, 0x10, 0x00,
                            0x00, 0x01,          /* ACL pkt len  = 256   */
                            0x3c,                /* sync pkt len = 60    */
                            0x0a, 0x00,          /* ACL packets  = 10    */
                            0x08, 0x00           /* sync packets = 8     */
                        };
                        if (write(g_our, r5, sizeof r5) != (int)sizeof r5)
                            LOGE("write фейка 1005: %s", strerror(errno));
                        LOGI("0x1005 (Read Buffer Size) перехвачен");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x1009) {
                        /* BootROM fw rejects Read BD_ADDR; return a fixed
                         * locally-administered address (efuse is empty). */
                        static const unsigned char r6[] = {
                            0x04, 0x0e, 0x0a, 0x01, 0x09, 0x10, 0x00,
                            0x01, 0x45, 0x45, 0x00, 0x9e, 0xca   /* CA:9E:00:45:45:01 */
                        };
                        if (write(g_our, r6, sizeof r6) != (int)sizeof r6)
                            LOGE("write фейка 1009: %s", strerror(errno));
                        LOGI("0x1009 (Read BD_ADDR) перехвачен -> CA:9E:00:45:45:01");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (oc == 0x0C14) {
                        /* BootROM fw rejects Read Local Name (0x0C14) with
                         * 0x11 and the GD stack asserts.  Answer with a
                         * fixed local name instead. */
                        static unsigned char r3[3 + 1 + 2 + 1 + 248];
                        r3[0]=0x04; r3[1]=0x0e; r3[2]=0xfc; r3[3]=0x01;
                        r3[4]=0x14; r3[5]=0x0c; r3[6]=0x00;
                        memset(r3+7, 0, 248);
                        memcpy(r3+7, "NGP45HT", 7);
                        if (write(g_our, r3, sizeof r3) != (int)sizeof r3)
                            LOGE("write фейка 0C14: %s", strerror(errno));
                        LOGI("0x0C14 (Read Local Name) перехвачен -> NGP45HT");
                        memmove(tx, tx + len, txn - len);
                        txn -= len;
                        continue;
                    }
                    if (write(g_hci, tx, len) != len)
                        LOGE("write в hci: %s", strerror(errno));
                    memmove(tx, tx + len, txn - len);
                    txn -= len;
                }
            } else if (n == 0) { break; }
            else if (errno != EAGAIN && errno != EINTR) {
                LOGE("read HAL: %s", strerror(errno)); break;
            }
        }
        if ((p[0].revents | p[1].revents) & (POLLERR | POLLHUP)) break;
    }
    LOGI("ретранслятор остановлен");
    return NULL;
}

static int userial_open(int (*fds)[CH_MAX])
{
    struct sockaddr_hci_ a;
    int sv[2], c;

    c = socket(AF_BLUETOOTH_, SOCK_RAW, BTPROTO_HCI_);
    if (c >= 0) { ioctl(c, HCIDEVDOWN_, HCI_DEV_ID); close(c); }

    g_hci = socket(AF_BLUETOOTH_, SOCK_RAW, BTPROTO_HCI_);
    if (g_hci < 0) { LOGE("socket: %s", strerror(errno)); return 0; }

    memset(&a, 0, sizeof a);
    a.hci_family = AF_BLUETOOTH_; a.hci_dev = HCI_DEV_ID;
    a.hci_channel = HCI_CHANNEL_USER_;
    if (bind(g_hci, (struct sockaddr *)&a, sizeof a) < 0) {
        LOGE("bind(HCI_CHANNEL_USER): %s", strerror(errno));
        close(g_hci); g_hci = -1; return 0;
    }

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        LOGE("socketpair: %s", strerror(errno));
        close(g_hci); g_hci = -1; return 0;
    }
    g_our = sv[0]; g_hal = sv[1];

    g_run = 1;
    if (pthread_create(&g_relay, NULL, relay, NULL) != 0) {
        LOGE("pthread_create: %s", strerror(errno));
        close(g_hci); close(g_our); close(g_hal);
        g_hci = g_our = g_hal = -1; return 0;
    }

    LOGI("hci%d захвачен, ретранслятор поднят, fd для HAL=%d", HCI_DEV_ID, g_hal);
    (*fds)[0] = g_hal;
    return 1;
}

static void userial_close(void)
{
    if (!g_run && g_hci < 0) return;
    g_run = 0;
    if (g_our >= 0) { shutdown(g_our, SHUT_RDWR); }
    pthread_join(g_relay, NULL);
    if (g_our >= 0) { close(g_our); g_our = -1; }
    if (g_hci >= 0) { close(g_hci); g_hci = -1; }
    g_hal = -1;   /* этот конец закрывает HAL */
}

static int vnd_init(const vnd_callbacks_t *cb, unsigned char *bdaddr)
{
    (void)bdaddr; g_cb = cb;
    LOGI("init");
    return 0;
}

static int vnd_op(int opcode, void *param)
{
    LOGI("op(%d)", opcode);
    switch (opcode) {
    case OP_POWER_CTRL:   return 0;
    case OP_USERIAL_OPEN: return userial_open((int (*)[CH_MAX])param);
    case OP_USERIAL_CLOSE: userial_close(); return 0;
    case OP_FW_CFG:  if (g_cb && g_cb->fwcfg_cb)  g_cb->fwcfg_cb(RESULT_SUCCESS);  return 0;
    case OP_SCO_CFG: if (g_cb && g_cb->scocfg_cb) g_cb->scocfg_cb(RESULT_SUCCESS); return 0;
    case OP_LPM_SET_MODE: if (g_cb && g_cb->lpm_cb) g_cb->lpm_cb(RESULT_SUCCESS);  return 0;
    case OP_SET_AUDIO_STATE:
        if (g_cb && g_cb->audio_state_cb) g_cb->audio_state_cb(RESULT_SUCCESS); return 0;
    case OP_EPILOG:  if (g_cb && g_cb->epilog_cb) g_cb->epilog_cb(RESULT_SUCCESS); return 0;
    case OP_GET_LPM_IDLE_TIMEOUT: if (param) *((uint32_t *)param) = 0; return 0;
    default: return 0;
    }
}

static void vnd_cleanup(void)
{
    LOGI("cleanup");
    userial_close();
    g_cb = NULL;
}

__attribute__((visibility("default")))
const vnd_interface_t BLUETOOTH_VENDOR_LIB_INTERFACE = {
    sizeof(vnd_interface_t), vnd_init, vnd_op, vnd_cleanup
};
