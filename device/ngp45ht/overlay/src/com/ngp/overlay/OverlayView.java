package com.ngp.overlay;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.util.TypedValue;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

/** 半透明浮层：等宽字体多行文本，最后一行（FPS）单独着色。 */
public class OverlayView extends View {

    private final Paint bg = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint border = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint text = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();

    private List<String> lines = new ArrayList<>();
    private int fpsColor = 0xFFEDEDED;

    private final float lineHeight;
    private final float padH;
    private final float padV;
    private final float radius;

    public OverlayView(Context ctx) {
        super(ctx);
        float d = getResources().getDisplayMetrics().density;
        padH = 10 * d;
        padV = 7 * d;
        radius = 7 * d;

        text.setTypeface(Typeface.MONOSPACE);
        text.setTextSize(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_SP, 13, getResources().getDisplayMetrics()));
        text.setColor(0xFFEDEDED);
        text.setSubpixelText(true);

        Paint.FontMetrics fm = text.getFontMetrics();
        lineHeight = (fm.descent - fm.ascent) * 1.22f;

        bg.setColor(0xC4000000);
        border.setStyle(Paint.Style.STROKE);
        border.setStrokeWidth(1f * d);
        border.setColor(0x40FFFFFF);
    }

    public void setData(List<String> lines, int fpsColor) {
        this.lines = lines;
        this.fpsColor = fpsColor;
        requestLayout();
        invalidate();
    }

    private float textWidth() {
        float w = 0;
        for (String s : lines) w = Math.max(w, text.measureText(s));
        return w * 1.04f + 4f;   // 留余量：不同字体回退时 measureText 会略小于实际绘制宽度
    }

    @Override
    protected void onMeasure(int wSpec, int hSpec) {
        int w = (int) Math.ceil(textWidth() + padH * 2);
        int h = (int) Math.ceil(lineHeight * Math.max(1, lines.size()) + padV * 2);
        setMeasuredDimension(w, h);
    }

    @Override
    protected void onDraw(Canvas c) {
        rect.set(0, 0, getWidth(), getHeight());
        c.drawRoundRect(rect, radius, radius, bg);
        c.drawRoundRect(rect, radius, radius, border);

        Paint.FontMetrics fm = text.getFontMetrics();
        float y = padV - fm.ascent;
        for (int i = 0; i < lines.size(); i++) {
            text.setColor(i == lines.size() - 1 ? fpsColor : 0xFFEDEDED);
            c.drawText(lines.get(i), padH, y, text);
            y += lineHeight;
        }
        text.setColor(0xFFEDEDED);
    }
}
