/*
 * Copyright (C) 2023 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.android.settings.spa.preference

import android.content.Context
import android.os.SystemClock
import android.util.AttributeSet
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import androidx.annotation.VisibleForTesting
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.preference.Preference
import androidx.preference.PreferenceViewHolder
import com.android.settings.R
import com.android.settingslib.spa.framework.theme.SettingsTheme

open class ComposePreference @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
    defStyleRes: Int = 0,
) : Preference(context, attrs, defStyleAttr, defStyleRes) {
    private var content: @Composable () -> Unit = {}

    fun setContent(content: @Composable () -> Unit) {
        this.content = content
    }

    @VisibleForTesting
    @Composable
    fun Content() {
        content()
    }

    init {
        layoutResource = R.layout.preference_compose
    }

    override fun onBindViewHolder(holder: PreferenceViewHolder) {
        super.onBindViewHolder(holder)
        holder.isDividerAllowedAbove = false
        holder.isDividerAllowedBelow = false

        (holder.itemView as ComposeView).apply {
            setViewCompositionStrategy(ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed)
            setContent {
                SettingsTheme {
                    content()
                }
            }
            // RG52: нажатие с крестовины. Фокус списка настроек стоит на строке
            // (ComposeView), а не на кликабельном элементе Compose внутри неё, и
            // DPAD_CENTER уходил в никуда: «Developer options» в System, сброс
            // Bluetooth и Wi-Fi в Reset options и другие ComposePreference не
            // открывались с крестовины, только касанием. Касание Compose
            // обрабатывает правильно, поэтому «Enter» на строке превращается в
            // касание её центра. Если фокус уже внутри Compose, клавишу получает
            // элемент Compose, а не этот обработчик.
            setOnKeyListener { v, keyCode, event ->
                if (keyCode != KeyEvent.KEYCODE_DPAD_CENTER && keyCode != KeyEvent.KEYCODE_ENTER &&
                    keyCode != KeyEvent.KEYCODE_NUMPAD_ENTER && keyCode != KeyEvent.KEYCODE_BUTTON_A
                ) {
                    return@setOnKeyListener false
                }
                if (event.action == KeyEvent.ACTION_UP) tapCenter(v)
                true
            }
        }
    }

    private fun tapCenter(v: View) {
        val x = v.width / 2f
        val y = v.height / 2f
        val t = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(t, t, MotionEvent.ACTION_DOWN, x, y, 0)
        down.source = InputDevice.SOURCE_TOUCHSCREEN
        v.dispatchTouchEvent(down)
        down.recycle()
        val up = MotionEvent.obtain(t, t + 40, MotionEvent.ACTION_UP, x, y, 0)
        up.source = InputDevice.SOURCE_TOUCHSCREEN
        v.dispatchTouchEvent(up)
        up.recycle()
    }
}
