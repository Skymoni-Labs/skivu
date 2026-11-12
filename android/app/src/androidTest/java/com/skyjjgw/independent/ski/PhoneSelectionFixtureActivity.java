package com.skyjjgw.independent.ski;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.os.Bundle;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.CompoundButton;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

/** Isolated test APK page. Its real touch state is queried through ordered IPC. */
public class PhoneSelectionFixtureActivity extends Activity {
    public static volatile PhoneSelectionFixtureActivity instance;
    private static final int BLUE = Color.rgb(0, 120, 235);
    public volatile int page = 1;
    public volatile int optionTaps = 0;
    public volatile int nextTaps = 0;
    public volatile boolean ignoreTouches = false;
    public volatile boolean multiple;
    public String mode;
    private final boolean[] selected = {false, false};
    private final boolean[] lastSelection = {false, false};
    private final int[] optionCounts = {0, 0};
    private final CompoundButton[] controls = new CompoundButton[2];
    private TextView heading;
    private View surface;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        instance = this;
        mode = getIntent().getStringExtra("mode");
        if (mode == null) mode = "native";
        multiple = getIntent().getBooleanExtra("multiple", false) || "multiple".equals(mode);
        ignoreTouches = getIntent().getBooleanExtra("ignoreTouches", false);
        if ("canvas".equals(mode)) showCanvas(); else showNative();
    }

    private void counted(int index) {
        optionTaps++;
        optionCounts[index]++;
    }

    private void readNativeSelection() {
        for (int i = 0; i < controls.length; i++) selected[i] = controls[i].isChecked();
    }

    private void advance() {
        nextTaps++;
        System.arraycopy(selected, 0, lastSelection, 0, selected.length);
        page++;
        if (heading != null) heading.setText("第" + page + "页");
        if (surface != null) surface.invalidate();
    }

    private void showNative() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(40, 80, 40, 40);
        root.setBackgroundColor(Color.WHITE);
        heading = new TextView(this);
        heading.setText("第1页");
        heading.setTextSize(24);
        root.addView(heading);
        TextView question = new TextView(this);
        question.setText("请选择需要的选项");
        question.setTextSize(21);
        root.addView(question);
        LinearLayout choices;
        if (multiple) {
            choices = new LinearLayout(this);
            choices.setOrientation(LinearLayout.VERTICAL);
        } else {
            choices = new RadioGroup(this);
        }
        root.addView(choices);
        for (int i = 0; i < controls.length; i++) {
            final int index = i;
            CompoundButton option;
            if (multiple) {
                option = new CheckBox(this) {
                    @Override public boolean performClick() {
                        counted(index);
                        if (ignoreTouches) return true;
                        boolean accepted = super.performClick();
                        readNativeSelection();
                        return accepted;
                    }
                };
            } else {
                option = new RadioButton(this) {
                    @Override public boolean performClick() {
                        counted(index);
                        if (ignoreTouches) return true;
                        boolean accepted = super.performClick();
                        readNativeSelection();
                        return accepted;
                    }
                };
            }
            option.setId(View.generateViewId());
            option.setText(i == 0 ? "苹果" : "香蕉");
            option.setTextSize(22);
            option.setTextColor(Color.BLACK);
            option.setButtonTintList(ColorStateList.valueOf(BLUE));
            option.setMinHeight(100);
            controls[i] = option;
            choices.addView(option);
        }
        Button next = new Button(this);
        next.setText("下一页");
        next.setTextSize(22);
        next.setOnClickListener(view -> advance());
        root.addView(next);
        setContentView(root);
    }

    private void showCanvas() {
        surface = new View(this) {
            final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
            final RectF[] optionBounds = {new RectF(), new RectF()};
            final RectF next = new RectF();

            private void text(Canvas canvas, String value, float x, float y, float size, int color) {
                paint.setStyle(Paint.Style.FILL);
                paint.setTextAlign(Paint.Align.LEFT);
                paint.setTextSize(size);
                paint.setColor(color);
                canvas.drawText(value, x, y, paint);
            }

            @Override protected void onDraw(Canvas canvas) {
                canvas.drawColor(Color.WHITE);
                final float width = getWidth(), height = getHeight();
                final float size = width / 23f, radius = width * .040f;
                text(canvas, "第" + page + "页", width * .12f, height * .15f, size * 1.2f, Color.BLACK);
                text(canvas, "请选择需要的选项", width * .12f, height * .23f, size, Color.BLACK);
                for (int i = 0; i < 2; i++) {
                    float cx = width * .13f, cy = height * (.36f + .18f * i);
                    optionBounds[i].set(width * .06f, cy - radius * 1.7f, width * .82f, cy + radius * 1.7f);
                    RectF mark = new RectF(cx - radius, cy - radius, cx + radius, cy + radius);
                    paint.setColor(BLUE);
                    paint.setStrokeWidth(Math.max(3f, width / 240f));
                    paint.setStyle(selected[i] ? Paint.Style.FILL : Paint.Style.STROKE);
                    if (multiple) canvas.drawRect(mark, paint); else canvas.drawCircle(cx, cy, radius, paint);
                    if (multiple && selected[i]) {
                        paint.setColor(Color.WHITE);
                        paint.setStyle(Paint.Style.STROKE);
                        paint.setStrokeWidth(width / 150f);
                        Path check = new Path();
                        check.moveTo(mark.left + mark.width() * .20f, mark.top + mark.height() * .50f);
                        check.lineTo(mark.left + mark.width() * .40f, mark.top + mark.height() * .70f);
                        check.lineTo(mark.left + mark.width() * .80f, mark.top + mark.height() * .28f);
                        canvas.drawPath(check, paint);
                    }
                    if (!multiple) {
                        paint.setStyle(Paint.Style.FILL);
                        paint.setTextAlign(Paint.Align.CENTER);
                        paint.setTextSize(radius * .86f);
                        paint.setColor(selected[i] ? Color.WHITE : BLUE);
                        canvas.drawText(i == 0 ? "A" : "B", cx,
                            cy - (paint.ascent() + paint.descent()) / 2f, paint);
                    }
                    text(canvas, i == 0 ? "苹果" : "香蕉", width * .25f, cy + size * .35f, size, Color.BLACK);
                }
                next.set(width * .12f, height * .74f, width * .88f, height * .84f);
                paint.setColor(BLUE);
                paint.setStyle(Paint.Style.FILL);
                canvas.drawRoundRect(next, 12, 12, paint);
                paint.setTextAlign(Paint.Align.CENTER);
                paint.setTextSize(size);
                paint.setColor(Color.WHITE);
                canvas.drawText("下一页", next.centerX(), next.centerY() - (paint.ascent() + paint.descent()) / 2f, paint);
            }

            @Override public boolean onTouchEvent(MotionEvent event) {
                if (event.getAction() == MotionEvent.ACTION_UP) {
                    for (int i = 0; i < optionBounds.length; i++) {
                        if (optionBounds[i].contains(event.getX(), event.getY())) {
                            counted(i);
                            if (!ignoreTouches) {
                                if (multiple) selected[i] = !selected[i];
                                else { selected[0] = i == 0; selected[1] = i == 1; }
                                invalidate();
                            }
                            return true;
                        }
                    }
                    if (next.contains(event.getX(), event.getY())) advance();
                }
                return true;
            }
        };
        surface.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        setContentView(surface);
    }

    public JSONObject snapshot() {
        try {
            return new JSONObject().put("alive", true).put("mode", mode).put("multiple", multiple)
                .put("page", page).put("optionTaps", optionTaps).put("nextTaps", nextTaps)
                .put("selected", new JSONArray().put(selected[0]).put(selected[1]))
                .put("lastSelection", new JSONArray().put(lastSelection[0]).put(lastSelection[1]))
                .put("optionCounts", new JSONArray().put(optionCounts[0]).put(optionCounts[1]))
                .put("ignoreTouches", ignoreTouches);
        } catch (Exception error) { throw new IllegalStateException(error); }
    }

    @Override protected void onDestroy() {
        if (instance == this) instance = null;
        super.onDestroy();
    }
}
