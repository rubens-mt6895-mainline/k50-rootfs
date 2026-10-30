/**
 * K50 Safe Area — 避免 GNOME Shell 的元素落进机身圆角被切掉。
 *
 * 背景：面板 1440x3200，四角圆角半径约 70~90 物理像素。GNOME 的顶栏两端图标
 * （活动按钮 / 电池百分比）与软键盘最外圈按键都贴着逻辑边缘摆放，投到真机上
 * 正好落进圆角区，看起来就是"被切掉一截"。
 *
 * 两件事：
 *   1) 软键盘：给 #keyboard 加内缩 padding（CSS，APPLICATION 优先级，只影响 shell）
 *   2) 顶栏：把 panel 第一个/最后一个子盒子的左右 padding 用内联样式顶开
 *      （#panel 的 CSS padding 在这版 shell 里不生效，所以走内联）
 *
 * 参数可在 /home/k50/.config/k50-safe-area.json 覆盖，例如
 *   {"panelX": 44, "kbdX": 44, "kbdTop": 6, "kbdBottom": 30}
 * 改完 systemctl restart gdm 生效。
 */
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const DEFAULTS = {
    panelX: 44,
    kbdX: 44,
    kbdTop: 6,
    kbdBottom: 30,
};

function readConfig() {
    const cfg = Object.assign({}, DEFAULTS);
    try {
        const f = Gio.File.new_for_path(
            GLib.get_home_dir() + '/.config/k50-safe-area.json');
        if (!f.query_exists(null))
            return cfg;
        const [ok, data] = f.load_contents(null);
        if (!ok)
            return cfg;
        const obj = JSON.parse(new TextDecoder().decode(data));
        for (const k of Object.keys(DEFAULTS)) {
            if (typeof obj[k] === 'number' && obj[k] >= 0 && obj[k] < 200)
                cfg[k] = obj[k];
        }
    } catch (e) {
        console.warn('[k50-safe-area] 配置读取失败: ' + e);
    }
    return cfg;
}

export default class K50SafeAreaExtension extends Extension {
    enable() {
        this._cfg = readConfig();
        this._saved = [];

        // ---- 1. 软键盘：CSS ----
        const css = `
#keyboard {
    padding: ${this._cfg.kbdTop}px ${this._cfg.kbdX}px ${this._cfg.kbdBottom}px ${this._cfg.kbdX}px;
}
`;
        const path = GLib.build_filenamev([GLib.get_user_cache_dir(), 'k50-safe-area.css']);
        try {
            GLib.mkdir_with_parents(GLib.get_user_cache_dir(), 0o755);
            GLib.file_set_contents(path, css);
            this._file = Gio.File.new_for_path(path);
            this._theme = St.ThemeContext.get_for_stage(global.stage).get_theme();
            this._theme.load_stylesheet(this._file);
        } catch (e) {
            console.warn('[k50-safe-area] 键盘 CSS 失败: ' + e);
        }

        // ---- 2. 顶栏：内联 padding ----
        try {
            const panel = Main.panel;
            const kids = [];
            let c = panel.get_first_child();
            while (c) {
                kids.push(c);
                c = c.get_next_sibling();
            }

            const px = this._cfg.panelX;
            if (kids.length > 0) {
                const first = kids[0];
                this._saved.push([first, first.get_style()]);
                first.set_style(`padding-left: ${px}px;${first.get_style() ?? ''}`);

                const last = kids[kids.length - 1];
                if (last !== first) {
                    this._saved.push([last, last.get_style()]);
                    last.set_style(`padding-right: ${px}px;${last.get_style() ?? ''}`);
                }
            }

            console.warn(`[k50-safe-area] panel children=${kids.length} ` +
                kids.map(k => `${k.name ?? '?'}(x=${k.x},w=${k.width})`).join(' '));
        } catch (e) {
            console.warn('[k50-safe-area] 顶栏 padding 失败: ' + e);
        }

        console.warn(`[k50-safe-area] enabled panelX=${this._cfg.panelX} ` +
            `kbdX=${this._cfg.kbdX} kbdTop=${this._cfg.kbdTop} kbdBottom=${this._cfg.kbdBottom}`);
    }

    disable() {
        for (const [actor, style] of this._saved) {
            try {
                actor.set_style(style ?? null);
            } catch (e) {
                // 忽略
            }
        }
        this._saved = [];

        try {
            if (this._theme && this._file)
                this._theme.unload_stylesheet(this._file);
        } catch (e) {
            // 忽略
        }

        this._theme = null;
        this._file = null;
        console.warn('[k50-safe-area] disabled');
    }
}
