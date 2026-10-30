/**
 * K50 OSK Tweak
 *
 * 1) 键盘高度：给 GNOME Shell 内建软键盘调高（按键变大 + 整体上移）
 *    实测：global.stage / keyboardMonitor 都是 1600x720 的逻辑空间，原版 _relayout()
 *    走 width>height 的横屏分支 height=720/3=240 → 真机上按键被压扁。这里改成
 *    monitor.height * RATIO（默认 0.55 → 396）。
 *    比例可热更：写 /home/k50/.config/osk-ratio（下一个数字，0.2~0.95），
 *    下一次键盘弹出即生效，不用重启 shell。
 *
 * 2) 防误弹（strict tap）：默认只有"手指点在聚焦的输入框范围内"才弹键盘。
 *    程序化聚焦、点按钮后顺带聚焦、切窗口等一律不弹。
 *    配置 /home/k50/.config/osk-strict-tap.json：
 *      {"enabled": true, "graceMs": 700, "margin": 24}
 *    enabled=false 则退回原版行为（任何聚焦都弹）。
 *
 * 调试：存在 /tmp/osk-force 时每 3 秒检查一次，强制弹键盘并抓图到 /tmp/osk-visible.png
 *      （强制路径绕过 strict tap 判定）。
 */
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as KeyboardModule from 'resource:///org/gnome/shell/ui/keyboard.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import Shell from 'gi://Shell';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';

const DEFAULT_RATIO = 0.55;
const STRICT_DEFAULTS = {enabled: true, graceMs: 700, margin: 24};
const DIAG_LOG_LIMIT = 20;

let lastTouch = {x: -1, y: -1, time: 0};

function nowMs() {
    return GLib.get_monotonic_time() / 1000;
}

function readTextFile(path) {
    try {
        const f = Gio.File.new_for_path(path);
        if (!f.query_exists(null))
            return null;
        const [ok, data] = f.load_contents(null);
        return ok ? new TextDecoder().decode(data).trim() : null;
    } catch (e) {
        return null;
    }
}

function readRatio() {
    const s = readTextFile(GLib.get_home_dir() + '/.config/osk-ratio');
    if (!s)
        return null;
    const v = parseFloat(s);
    return isFinite(v) && v > 0.2 && v < 0.95 ? v : null;
}

function readStrict() {
    const cfg = Object.assign({}, STRICT_DEFAULTS);
    const s = readTextFile(GLib.get_home_dir() + '/.config/osk-strict-tap.json');
    if (!s)
        return cfg;
    try {
        const obj = JSON.parse(s);
        if (typeof obj.enabled === 'boolean')
            cfg.enabled = obj.enabled;
        if (typeof obj.graceMs === 'number' && obj.graceMs >= 0 && obj.graceMs <= 3000)
            cfg.graceMs = obj.graceMs;
        if (typeof obj.margin === 'number' && obj.margin >= 0 && obj.margin <= 200)
            cfg.margin = obj.margin;
    } catch (e) {
        console.warn('[osk-tweak] strict 配置解析失败: ' + e);
    }
    return cfg;
}

/** 只有"最近一次触摸点落在当前键盘焦点范围内"才允许弹键盘 */
function allowOpen() {
    const cfg = readStrict();
    if (!cfg.enabled)
        return true;

    const dt = nowMs() - lastTouch.time;
    if (lastTouch.time <= 0 || dt > cfg.graceMs) {
        console.warn(`[osk-tweak] 拦截弹键盘：无近期触摸（dt=${Math.round(dt)}ms）`);
        return false;
    }

    let focus = null;
    try {
        focus = global.stage.get_key_focus();
    } catch (e) {
        focus = null;
    }
    if (!focus)
        return true;   // 拿不到焦点就别拦，免得键盘永远不弹

    try {
        const box = focus.get_transformed_extents();
        const x1 = box.get_x() - cfg.margin;
        const y1 = box.get_y() - cfg.margin;
        const x2 = x1 + box.get_width() + 2 * cfg.margin;
        const y2 = y1 + box.get_height() + 2 * cfg.margin;
        const inside = lastTouch.x >= x1 && lastTouch.x <= x2 &&
                       lastTouch.y >= y1 && lastTouch.y <= y2;
        if (!inside) {
            console.warn(`[osk-tweak] 拦截弹键盘：触摸(${Math.round(lastTouch.x)},` +
                `${Math.round(lastTouch.y)}) 不在焦点框(${Math.round(x1)},${Math.round(y1)},` +
                `${Math.round(x2)},${Math.round(y2)}) 内`);
        }
        return inside;
    } catch (e) {
        return true;
    }
}

function grabShot(path) {
    try {
        const file = Gio.File.new_for_path(path);
        const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
        const p = new Shell.Screenshot().screenshot(false, stream);
        if (p && typeof p.then === 'function') {
            p.then(() => {
                stream.close(null);
                console.warn('[osk-tweak] shot ok -> ' + path);
            }).catch(e => console.warn('[osk-tweak] shot err ' + e));
        }
    } catch (e) {
        console.warn('[osk-tweak] shot threw: ' + e);
    }
}

export default class OskTweakExtension extends Extension {
    static _diagCount = 0;

    enable() {
        OskTweakExtension._diagCount = 0;
        this._shotDone = false;
        OskTweakExtension._instance = this;

        const proto = KeyboardModule.Keyboard.prototype;
        this._proto = proto;
        this._origRelayout = proto._relayout;
        this._origOpen = proto.open;

        // ---- 键盘高度 ----
        proto._relayout = function () {
            this._origRelayoutForOskTweak();
        };

        proto._origRelayoutForOskTweak = function () {
            const monitor = Main.layoutManager.keyboardMonitor;
            if (!monitor)
                return;

            const ratio = readRatio() ?? DEFAULT_RATIO;
            this.width = monitor.width;
            this.height = Math.round(monitor.height * ratio);

            if (this.translation_y < 0)
                this.translation_y = -this.height;

            if (OskTweakExtension._diagCount < DIAG_LOG_LIMIT) {
                OskTweakExtension._diagCount++;
                console.warn(`[osk-tweak] #${OskTweakExtension._diagCount} ratio=${ratio} ` +
                    `-> kbd=${this.width}x${this.height} ty=${this.translation_y}`);
            }
        };

        // ---- 防误弹 ----
        proto.open = function (monitor) {
            if (!allowOpen())
                return;
            return this._origOpenForOskTweak(monitor);
        };
        proto._origOpenForOskTweak = this._origOpen;

        // ---- 记录最近一次触摸 ----
        this._capturedId = global.stage.connect('captured-event', (_stage, event) => {
            const t = event.type();
            if (t === Clutter.EventType.TOUCH_BEGIN ||
                t === Clutter.EventType.TOUCH_UPDATE ||
                t === Clutter.EventType.BUTTON_PRESS) {
                try {
                    const [x, y] = event.get_coords();
                    lastTouch = {x, y, time: nowMs()};
                } catch (e) {
                    // 忽略
                }
            }
            return Clutter.EVENT_PROPAGATE;
        });

        const kb = Main.keyboard?._keyboard;
        if (kb) {
            try {
                kb._relayout();
            } catch (e) {
                console.warn('[osk-tweak] 初次 _relayout 失败: ' + e);
            }
        }

        // ---- 调试触发 ----
        this._forceTimeout = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            const f = Gio.File.new_for_path('/tmp/osk-force');
            if (f.query_exists(null)) {
                try {
                    f.delete(null);
                } catch (e) {
                    // 忽略
                }
                try {
                    const k = Main.keyboard?._keyboard;
                    if (k) {
                        // 绕过 strict tap，便于远端抓图
                        if (k._origOpenForOskTweak)
                            k._origOpenForOskTweak(0);
                        else
                            k.open(0);
                        console.warn('[osk-tweak] forced keyboard open');
                        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1500, () => {
                            grabShot('/tmp/osk-visible.png');
                            return GLib.SOURCE_REMOVE;
                        });
                    }
                } catch (e) {
                    console.warn('[osk-tweak] force open 失败: ' + e);
                }
            }
            return GLib.SOURCE_CONTINUE;
        });

        const strict = readStrict();
        console.warn(`[osk-tweak] enabled ratio=${readRatio() ?? DEFAULT_RATIO} ` +
            `strictTap=${strict.enabled} graceMs=${strict.graceMs} margin=${strict.margin}`);
    }

    disable() {
        OskTweakExtension._instance = null;

        if (this._capturedId) {
            global.stage.disconnect(this._capturedId);
            this._capturedId = 0;
        }

        if (this._forceTimeout) {
            GLib.source_remove(this._forceTimeout);
            this._forceTimeout = 0;
        }

        const proto = this._proto;
        if (!proto)
            return;

        delete proto._relayout;
        if (this._origRelayout)
            proto._relayout = this._origRelayout;
        delete proto._origRelayoutForOskTweak;

        if (this._origOpen)
            proto.open = this._origOpen;
        delete proto._origOpenForOskTweak;

        const kb = Main.keyboard?._keyboard;
        if (kb) {
            try {
                kb._relayout();
            } catch (e) {
                // 忽略
            }
        }

        this._proto = null;
        this._origRelayout = null;
        this._origOpen = null;
        console.warn('[osk-tweak] disabled');
    }
}
