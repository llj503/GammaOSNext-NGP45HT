package com.retrofront;

import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;

import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Per-game RetroArch core override for LANGOS.
 *
 * The normal LANGOS launch path asks getPlatformCore(platformId) for a core.
 * This helper stores an optional override keyed by the ROM path and resolves
 * it to the core file passed to RetroArch through the LIBRETRO extra.
 */
public final class CoreOptions {
    private static final String PREFS = "langos_core_overrides";
    private static final String DATA_CORES = "/data/data/com.retroarch.aarch64/cores/";
    private static final String ANDROID_SUFFIX = "_libretro_android.so";

    // Cores shipped in the NGP45HT RetroArch build. LANGOS cannot list
    // /data/data/com.retroarch.aarch64/cores directly (app sandbox), so this
    // list is the fallback when no readable cores folder is found.
    private static final String BUILTIN_CORES =
            "2048 81 a5200 arduous atari800 bk blastem bluemsx bsnes bsnes-jg "
            + "bsnes2014_accuracy bsnes2014_balanced bsnes2014_performance bsnes_hd_beta "
            + "bsnes_mercury_accuracy bsnes_mercury_balanced bsnes_mercury_performance "
            + "cannonball cap32 chailove clownmdemu craft crocods desmume desmume2015 "
            + "dinothawr dirksimple dolphin dosbox dosbox_core dosbox_pure dosbox_svn "
            + "DoubleCherryGB easyrpg ecwolf ep128emu_core fake08 fbalpha2012 "
            + "fbalpha2012_cps1 fbalpha2012_cps2 fbalpha2012_cps3 fbalpha2012_neogeo fbneo "
            + "fceumm ffmpeg flycast fmsx freechaf freeintv fuse gam4980 gambatte gearboy "
            + "gearcoleco gearsystem genesis_plus_gx genesis_plus_gx_wide gme gong gpsp gw "
            + "handy hatari hbmame jaxe jumpnbump lowresnx lutro mame2000 mame2003 "
            + "mame2003_midway mame2003_plus mame2010 mame2015 mame2016 mamearcade "
            + "mednafen_lynx mednafen_ngp mednafen_pce mednafen_pce_fast mednafen_pcfx "
            + "mednafen_psx mednafen_psx_hw mednafen_saturn mednafen_supafaust "
            + "mednafen_supergrafx mednafen_vb mednafen_wswan melonds melondsds mesen "
            + "mesen-s mgba minivmac mojozork mrboom mu mupen64plus_next_gles2 "
            + "mupen64plus_next_gles3 nekop2 neocd nestopia np2kai numero nxengine o2em "
            + "oberon openlara opera parallel_n64 pcsx_rearmed picodrive pocketcdg pokemini "
            + "potator ppsspp prboom prosystem puae puae2021 px68k quasi88 quicknes race "
            + "reminiscence retro8 sameboy sameduck scummvm skyemu smsplus snes9x "
            + "snes9x2002 snes9x2005 snes9x2005_plus snes9x2010 squirreljme stella stella2014 "
            + "superbroswar swanstation tgbdual theodore thepowdertoy tic80 tyrquake uw8 "
            + "uzem vaporspec vba_next vbam vecx vemulator vice_x128 vice_x64 vice_x64sc "
            + "vice_xcbm2 vice_xcbm5x0 vice_xpet vice_xplus4 vice_xscpu64 vice_xvic "
            + "vircon32 virtualjaguar virtualxt vitaquake2 vitaquake2-rogue vitaquake2-xatrix "
            + "vitaquake2-zaero wasm4 x1 xrick yabasanshiro yabause";

    private static final String[] CORES_ARCADE = {
            "fbneo", "fbalpha2012", "fbalpha2012_neogeo", "fbalpha2012_cps1",
            "fbalpha2012_cps2", "fbalpha2012_cps3", "hbmame", "mame2003_plus",
            "mame2010", "mame2000", "mame2003", "mame2003_midway", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_CPS1 = {
            "fbalpha2012_cps1", "fbneo", "fbalpha2012", "fbalpha2012_cps2",
            "fbalpha2012_cps3", "fbalpha2012_neogeo", "hbmame", "mame2003_plus",
            "mame2010", "mame2000", "mame2003", "mame2003_midway", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_CPS2 = {
            "fbalpha2012_cps2", "fbneo", "fbalpha2012", "fbalpha2012_cps1",
            "fbalpha2012_cps3", "fbalpha2012_neogeo", "hbmame", "mame2003_plus",
            "mame2010", "mame2000", "mame2003", "mame2003_midway", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_CPS3 = {
            "fbalpha2012_cps3", "fbneo", "fbalpha2012", "fbalpha2012_cps1",
            "fbalpha2012_cps2", "fbalpha2012_neogeo", "hbmame", "mame2003_plus",
            "mame2010", "mame2000", "mame2003", "mame2003_midway", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_NEOGEO = {
            "fbalpha2012_neogeo", "fbneo", "fbalpha2012", "fbalpha2012_cps1",
            "fbalpha2012_cps2", "fbalpha2012_cps3", "hbmame", "mame2003_plus",
            "mame2010", "mame2000", "mame2003", "mame2003_midway", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_MAME2003 = {
            "mame2003", "mame2003_plus", "mame2003_midway", "fbneo", "fbalpha2012",
            "fbalpha2012_neogeo", "fbalpha2012_cps1", "fbalpha2012_cps2",
            "fbalpha2012_cps3", "hbmame", "mame2010", "mame2000", "mame2015",
            "mame2016", "mamearcade"
    };
    private static final String[] CORES_NES = {"fceumm", "nestopia", "quicknes", "mesen"};
    private static final String[] CORES_SNES = {
            "snes9x", "snes9x2010", "snes9x2005", "snes9x2005_plus", "snes9x2002",
            "bsnes", "bsnes2014_accuracy", "bsnes2014_balanced", "bsnes2014_performance",
            "bsnes_mercury_accuracy", "bsnes_mercury_balanced", "bsnes_mercury_performance",
            "bsnes_hd_beta", "bsnes-jg", "mesen-s", "mednafen_supafaust"
    };
    private static final String[] CORES_GB = {
            "gambatte", "sameboy", "DoubleCherryGB", "gearboy", "skyemu", "tgbdual"
    };
    private static final String[] CORES_GBA = {"mgba", "gpsp", "vba_next", "vbam", "skyemu"};
    private static final String[] CORES_N64 = {
            "mupen64plus_next_gles2", "mupen64plus_next_gles3", "parallel_n64"
    };
    private static final String[] CORES_NDS = {
            "melonds", "melondsds", "desmume", "desmume2015", "skyemu"
    };
    private static final String[] CORES_PSX = {
            "pcsx_rearmed", "mednafen_psx", "mednafen_psx_hw", "swanstation"
    };
    private static final String[] CORES_PSP = {"ppsspp"};
    private static final String[] CORES_MD = {
            "genesis_plus_gx", "genesis_plus_gx_wide", "picodrive", "blastem", "clownmdemu"
    };
    private static final String[] CORES_SMS = {
            "genesis_plus_gx", "genesis_plus_gx_wide", "gearsystem", "smsplus", "picodrive"
    };
    private static final String[] CORES_NGPC = {"mednafen_ngp", "race"};
    private static final String[] CORES_DREAMCAST = {"flycast"};
    private static final String[] CORES_SATURN = {"mednafen_saturn", "yabause", "yabasanshiro"};
    private static final String[] CORES_PCE = {
            "mednafen_pce", "mednafen_pce_fast", "mednafen_supergrafx"
    };
    private static final String[] CORES_WSWAN = {"mednafen_wswan"};
    private static final String[] CORES_LYNX = {"handy", "mednafen_lynx"};
    private static final String[] CORES_VB = {"mednafen_vb"};
    private static final String[] CORES_ATARI2600 = {"stella", "stella2014"};
    private static final String[] CORES_ATARI7800 = {"prosystem"};
    private static final String[] CORES_3DO = {"opera"};
    private static final String[] CORES_C64 = {"vice_x64", "vice_x64sc"};
    private static final String[] CORES_AMIGA = {"puae", "puae2021"};
    private static final String[] CORES_DOS = {"dosbox", "dosbox_core", "dosbox_pure", "dosbox_svn"};
    private static final String[] CORES_MSX = {"bluemsx", "fmsx"};
    private static final String[] CORES_ZX = {"fuse", "vaporspec"};
    private static final String[] CORES_PC98 = {"np2kai"};
    private static final String[] CORES_X68000 = {"px68k"};
    private static final String[] CORES_PC88 = {"quasi88"};
    private static final String[] CORES_JAGUAR = {"virtualjaguar"};
    private static final String[] CORES_NEOCD = {"neocd"};

    private CoreOptions() {
    }

    /** Called from NativeActivity.startGame(): full core path or null for the default. */
    public static String resolveOverride(Context context, String romPath) {
        if (romPath == null) {
            return null;
        }
        String core = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(romPath, null);
        if (core == null || core.length() == 0) {
            return null;
        }
        return DATA_CORES + core + ANDROID_SUFFIX;
    }

    /** Called from GameDetailDialog.createView(): adds the selector above the buttons. */
    public static void install(Context context, LinearLayout parent, String romPath,
                               String platformId, String defaultCore) {
        String rawPid = platformId == null ? "" : platformId.toLowerCase();
        if (rawPid.equals("android") || rawPid.equals("androidapps") || rawPid.equals("安卓app")
                || isAndroidApp(romPath)) {
            return;
        }
        final Context ctx = context;
        final String pid = inferPlatform(platformId, romPath);
        final String def = defaultFor(normalizeDefault(defaultCore), pid);
        final List<String> choices = orderedCores(pid, def);
        if (choices.size() < 2) {
            return;
        }
        final Button btn = new Button(ctx);
        btn.setAllCaps(false);
        btn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f);
        btn.setTextColor(Color.WHITE);
        btn.setPadding(dp(ctx, 16), dp(ctx, 10), dp(ctx, 16), dp(ctx, 10));
        btn.setBackground(buildBackground());
        btn.setTag("core_btn");
        btn.setFocusable(true);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.setMargins(dp(ctx, 8), dp(ctx, 10), dp(ctx, 8), 0);
        btn.setLayoutParams(lp);
        updateButton(ctx, btn, romPath, def);
        btn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showPicker(ctx, btn, romPath, choices, def);
            }
        });
        int index = parent.getChildCount();
        parent.addView(btn, index > 0 ? index - 1 : 0);
    }

    private static void showPicker(final Context ctx, final Button btn, final String romPath,
                                   final List<String> cores, final String defaultCore) {
        final String[] items = new String[cores.size() + 1];
        items[0] = "自动（默认" + (isEmpty(defaultCore) ? "" : ": " + defaultCore) + "）";
        for (int i = 0; i < cores.size(); i++) {
            items[i + 1] = cores.get(i);
        }
        SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String current = prefs.getString(romPath, null);
        int checked = 0;
        if (current != null && current.length() > 0) {
            int at = cores.indexOf(current);
            if (at >= 0) {
                checked = at + 1;
            }
        }
        new AlertDialog.Builder(ctx)
                .setTitle("选择游戏核心")
                .setSingleChoiceItems(items, checked, new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface dialog, int which) {
                        SharedPreferences.Editor editor = ctx
                                .getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit();
                        if (which == 0) {
                            editor.remove(romPath);
                        } else {
                            editor.putString(romPath, cores.get(which - 1));
                        }
                        editor.apply();
                        updateButton(ctx, btn, romPath, defaultCore);
                        dialog.dismiss();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private static void updateButton(Context ctx, Button btn, String romPath, String defaultCore) {
        String core = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(romPath, null);
        String shown;
        if (core == null || core.length() == 0) {
            shown = "自动" + (isEmpty(defaultCore) ? "" : "（" + defaultCore + "）");
        } else {
            shown = core;
        }
        btn.setText("游戏核心: " + shown + "  ▼");
    }

    private static List<String> orderedCores(String platformId, String defaultCore) {
        List<String> available = listCores();
        String[] wanted = coresForPlatform(platformId);
        List<String> result = new ArrayList<String>();
        if (wanted != null) {
            for (String core : wanted) {
                if (available.contains(core) && !result.contains(core)) {
                    result.add(core);
                }
            }
        }
        if (result.isEmpty() && !isEmpty(defaultCore) && available.contains(defaultCore)) {
            result.add(defaultCore);
        }
        if (!isEmpty(defaultCore)) {
            int at = result.indexOf(defaultCore);
            if (at > 0) {
                result.remove(at);
                result.add(0, defaultCore);
            }
        }
        return result;
    }

    private static boolean isAndroidApp(String romPath) {
        if (romPath == null) {
            return false;
        }
        return romPath.startsWith("com.") || romPath.startsWith("org.")
                || romPath.startsWith("net.");
    }

    private static String normalizeDefault(String value) {
        if (value == null || value.length() == 0 || "default".equalsIgnoreCase(value)) {
            return "";
        }
        return value;
    }

    private static String defaultFor(String current, String platformId) {
        if (current.length() > 0) {
            return current;
        }
        String s = platformId == null ? "" : platformId.toLowerCase();
        if (s.startsWith("mame")) {
            return "mame2010";
        }
        if (s.equals("arcade") || s.equals("varcade") || s.equals("neogeo")
                || s.equals("ng") || s.equals("cps1") || s.equals("cps2")
                || s.equals("cps3") || s.startsWith("fbneo")) {
            return "fbneo";
        }
        return "";
    }

    private static String inferPlatform(String platformId, String romPath) {
        if (platformId != null && platformId.length() > 0 && !"default".equalsIgnoreCase(platformId)) {
            return platformId;
        }
        if (romPath == null) {
            return "";
        }
        String lower = romPath.toLowerCase();
        int at = lower.indexOf("/roms/");
        if (at >= 0) {
            String rest = romPath.substring(at + 6);
            int slash = rest.indexOf('/');
            if (slash > 0) {
                return rest.substring(0, slash);
            }
        }
        String[] known = {"arcade", "cps1", "cps2", "cps3", "fbneo", "mame", "neogeo", "varcade"};
        for (String name : known) {
            if (lower.contains("/" + name + "/")) {
                return name;
            }
        }
        return "";
    }

    private static String[] coresForPlatform(String platformId) {
        String p = normalizePlatform(platformId);
        if (p.equals("arcade") || p.equals("varcade") || p.equals("mame")
                || p.startsWith("fbneo")) {
            return CORES_ARCADE;
        }
        if (p.equals("cps1")) {
            return CORES_CPS1;
        }
        if (p.equals("cps2")) {
            return CORES_CPS2;
        }
        if (p.equals("cps3")) {
            return CORES_CPS3;
        }
        if (p.equals("neocd")) {
            return CORES_NEOCD;
        }
        if (p.equals("neogeo")) {
            return CORES_NEOGEO;
        }
        if (p.startsWith("mame")) {
            return CORES_MAME2003;
        }
        if (p.equals("nes")) {
            return CORES_NES;
        }
        if (p.equals("snes")) {
            return CORES_SNES;
        }
        if (p.equals("gb") || p.equals("gbc")) {
            return CORES_GB;
        }
        if (p.equals("gba")) {
            return CORES_GBA;
        }
        if (p.equals("n64")) {
            return CORES_N64;
        }
        if (p.equals("nds")) {
            return CORES_NDS;
        }
        if (p.equals("psx")) {
            return CORES_PSX;
        }
        if (p.equals("psp")) {
            return CORES_PSP;
        }
        if (p.equals("megadrive")) {
            return CORES_MD;
        }
        if (p.equals("mastersystem") || p.equals("gamegear")) {
            return CORES_SMS;
        }
        if (p.equals("ngpc")) {
            return CORES_NGPC;
        }
        if (p.equals("dreamcast")) {
            return CORES_DREAMCAST;
        }
        if (p.equals("saturn")) {
            return CORES_SATURN;
        }
        if (p.equals("pce")) {
            return CORES_PCE;
        }
        if (p.equals("wswan")) {
            return CORES_WSWAN;
        }
        if (p.equals("lynx")) {
            return CORES_LYNX;
        }
        if (p.equals("vb")) {
            return CORES_VB;
        }
        if (p.equals("atari2600")) {
            return CORES_ATARI2600;
        }
        if (p.equals("atari7800")) {
            return CORES_ATARI7800;
        }
        if (p.equals("3do")) {
            return CORES_3DO;
        }
        if (p.equals("c64")) {
            return CORES_C64;
        }
        if (p.equals("amiga")) {
            return CORES_AMIGA;
        }
        if (p.equals("dos")) {
            return CORES_DOS;
        }
        if (p.equals("msx")) {
            return CORES_MSX;
        }
        if (p.equals("zxspectrum")) {
            return CORES_ZX;
        }
        if (p.equals("pc98")) {
            return CORES_PC98;
        }
        if (p.equals("x68000")) {
            return CORES_X68000;
        }
        if (p.equals("pc88")) {
            return CORES_PC88;
        }
        if (p.equals("jaguar")) {
            return CORES_JAGUAR;
        }
        return null;
    }

    private static String normalizePlatform(String platformId) {
        if (platformId == null) {
            return "";
        }
        String p = platformId.trim().toLowerCase();
        if (p.equals("famicom")) {
            return "nes";
        }
        if (p.equals("sfc")) {
            return "snes";
        }
        if (p.equals("genesis") || p.equals("md")) {
            return "megadrive";
        }
        if (p.equals("sms")) {
            return "mastersystem";
        }
        if (p.equals("gg")) {
            return "gamegear";
        }
        if (p.equals("ps1") || p.equals("ps")) {
            return "psx";
        }
        if (p.equals("ng")) {
            return "neogeo";
        }
        if (p.equals("dc")) {
            return "dreamcast";
        }
        if (p.equals("pcengine")) {
            return "pce";
        }
        if (p.equals("ws") || p.equals("wsc") || p.equals("wonderswan")) {
            return "wswan";
        }
        if (p.equals("2600")) {
            return "atari2600";
        }
        if (p.equals("7800")) {
            return "atari7800";
        }
        if (p.equals("zx")) {
            return "zxspectrum";
        }
        return p;
    }

    private static List<String> listCores() {
        Set<String> names = new LinkedHashSet<String>();
        addDir(names, new File(DATA_CORES));
        addDir(names, new File("/storage/emulated/0/RetroArch/cores"));
        addDir(names, new File("/storage/emulated/0/Android/data/com.retroarch.aarch64/files/cores"));
        if (names.isEmpty()) {
            String[] builtin = BUILTIN_CORES.split(" ");
            for (String core : builtin) {
                if (core.length() > 0) {
                    names.add(core);
                }
            }
        }
        List<String> list = new ArrayList<String>(names);
        Collections.sort(list, String.CASE_INSENSITIVE_ORDER);
        return list;
    }

    private static void addDir(Set<String> names, File dir) {
        File[] files = dir.listFiles();
        if (files == null) {
            return;
        }
        for (File file : files) {
            if (file.isFile()) {
                addCore(names, file.getName());
            }
        }
    }

    private static void addCore(Set<String> names, String fileName) {
        if (fileName == null) {
            return;
        }
        String name = fileName.trim();
        if (name.endsWith(ANDROID_SUFFIX)) {
            name = name.substring(0, name.length() - ANDROID_SUFFIX.length());
        } else if (name.endsWith("_libretro.so")) {
            name = name.substring(0, name.length() - "_libretro.so".length());
        } else {
            return;
        }
        if (name.length() > 0) {
            names.add(name);
        }
    }

    private static StateListDrawable buildBackground() {
        StateListDrawable states = new StateListDrawable();
        states.addState(new int[]{android.R.attr.state_focused},
                rounded(Color.parseColor("#3a5f8f"), Color.parseColor("#9cc8ff"), 3));
        states.addState(new int[]{android.R.attr.state_pressed},
                rounded(Color.parseColor("#446a99"), Color.parseColor("#9cc8ff"), 3));
        states.addState(new int[]{},
                rounded(Color.parseColor("#2b3a55"), Color.parseColor("#5a7aa6"), 2));
        return states;
    }

    private static GradientDrawable rounded(int fill, int stroke, int strokeWidth) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setShape(GradientDrawable.RECTANGLE);
        drawable.setCornerRadius(24f);
        drawable.setColor(fill);
        drawable.setStroke(strokeWidth, stroke);
        return drawable;
    }

    private static int dp(Context ctx, int value) {
        return (int) (value * ctx.getResources().getDisplayMetrics().density + 0.5f);
    }

    private static boolean isEmpty(String value) {
        return value == null || value.length() == 0;
    }
}
