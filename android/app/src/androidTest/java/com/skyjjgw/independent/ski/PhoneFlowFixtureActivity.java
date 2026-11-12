package com.skyjjgw.independent.ski;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.widget.*;

/** Test APK only: rapidly changing clock plus deterministic native form controls. */
public class PhoneFlowFixtureActivity extends Activity {
    public static PhoneFlowFixtureActivity current;
    private final Handler handler = new Handler();
    private int ticks = 0;
    private int question = 1;
    private LinearLayout card;
    private TextView clock;
    private final Runnable ticker = new Runnable() {
        @Override public void run() {
            if (current != PhoneFlowFixtureActivity.this) return;
            clock.setText("Clock " + (++ticks));
            handler.postDelayed(this, 75);
        }
    };
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        current = this;
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(28, 40, 28, 20);
        clock = new TextView(this); root.addView(clock);
        card = new LinearLayout(this); card.setOrientation(LinearLayout.VERTICAL);
        card.setContentDescription("question-card"); root.addView(card);
        setContentView(root);
        showQuestion(); ticker.run();
    }
    private void showQuestion() {
        card.removeAllViews();
        TextView title = new TextView(this);
        title.setText(question <= 20 ? "Question " + question : "Completed 20 questions");
        title.setTextSize(22); card.addView(title);
        if (question > 20) return;
        for (String label : new String[]{"Option A", "Option B"}) {
            CheckBox option = new CheckBox(this); option.setText(label); card.addView(option);
        }
        EditText input = new EditText(this); input.setId(android.R.id.edit);
        input.setHint("Fixture input"); card.addView(input);
        Button next = new Button(this); next.setAllCaps(false); next.setText("Next"); card.addView(next);
        next.setOnClickListener(view -> { question++; showQuestion(); });
    }
    public void addConfirmation() {
        TextView confirmation = new TextView(this);
        confirmation.setText("Later confirmation"); card.addView(confirmation);
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.getBooleanExtra("confirm", false)) addConfirmation();
    }
    @Override protected void onDestroy() {
        if (current == this) current = null;
        handler.removeCallbacks(ticker);
        super.onDestroy();
    }
}
