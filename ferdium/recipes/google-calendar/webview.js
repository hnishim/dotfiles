function _interopRequireDefault(obj) {
  return obj && obj.__esModule ? obj : { default: obj };
}

const _path = _interopRequireDefault(require('path'));
const fs = require('fs');
const os = require('os');

// 外部アセットは変更されない固定コミットのみを参照する。
const FERDIUM_RECIPES_COMMIT =
  '713a79b3200a381b2fd6816699949ca553b48d94';
const GOOGLE_CALENDAR_ASSET_BASE =
  `https://cdn.jsdelivr.net/gh/ferdium/ferdium-recipes@${FERDIUM_RECIPES_COMMIT}/recipes/google-calendar`;

// タブ間で共有する一時ファイルのパス
const syncFilePath = _path.default.join(os.tmpdir(), 'ferdium_gcal_sync.json');
const validViews = new Set(['day', 'week', 'month', 'year', 'custom', 'agenda']);

const isValidCalendarState = state => {
  if (!state || typeof state !== 'object' || !validViews.has(state.view)) {
    return false;
  }

  if (!/^\d{4}$/.test(state.year) ||
      !/^\d{1,2}$/.test(state.month) ||
      !/^\d{1,2}$/.test(state.day)) {
    return false;
  }

  const month = Number(state.month);
  const day = Number(state.day);
  return month >= 1 && month <= 12 && day >= 1 && day <= 31;
};

module.exports = Ferdium => {
  // 自身のタブを識別する一意のID
  const myTabId = Math.random().toString(36).substring(2, 9);

  // user.jsからの書き込み要求をフックしてファイルに保存
  window.addEventListener('ferdium_gcal_send_state', (event) => {
    const state = event.detail;
    if (!isValidCalendarState(state)) {
      console.warn('[GCal Sync] 不正なカレンダー状態を破棄しました:', state);
      return;
    }

    const payload = {
      ...state,
      senderId: myTabId,
      timestamp: Date.now(),
    };
    const temporaryPath = `${syncFilePath}.${process.pid}.${myTabId}.tmp`;

    try {
      fs.writeFileSync(temporaryPath, JSON.stringify(payload), {
        encoding: 'utf8',
        mode: 0o600,
      });
      fs.renameSync(temporaryPath, syncFilePath);
    } catch (err) {
      try {
        fs.unlinkSync(temporaryPath);
      } catch (cleanupError) {
        if (cleanupError.code !== 'ENOENT') {
          console.error('[GCal Sync] 一時ファイルの削除に失敗しました:', cleanupError);
        }
      }
      console.error('[GCal Sync] 状態ファイルの書き込みに失敗しました:', err);
    }
  });

  // 共有ファイルを定期監視して他タブの更新を検知
  let lastMtime = 0;
  setInterval(() => {
    try {
      if (!fs.existsSync(syncFilePath)) return;
      const stats = fs.statSync(syncFilePath);
      if (stats.mtimeMs <= lastMtime) return;
      lastMtime = stats.mtimeMs;

      const content = fs.readFileSync(syncFilePath, 'utf8');
      if (!content) return;
      const data = JSON.parse(content);
      if (!isValidCalendarState(data) ||
          typeof data.senderId !== 'string' ||
          !Number.isFinite(data.timestamp)) {
        console.warn('[GCal Sync] 不正な同期データを破棄しました:', data);
        return;
      }

      // 他のタブが3秒以内に書き込んだデータであればuser.jsへ通知
      if (data && data.senderId !== myTabId && (Date.now() - data.timestamp < 3000)) {
        const customEvent = new CustomEvent('ferdium_gcal_receive_state', { detail: data });
        window.dispatchEvent(customEvent);
      }
    } catch (err) {
      console.error('[GCal Sync] 状態ファイルの読み込みに失敗しました:', err);
    }
  }, 400);

  if (
    location.hostname === 'workspace.google.com' &&
    location.href.includes('products/calendar/')
  ) {
    location.href =
      'https://accounts.google.com/AccountChooser?continue=https://calendar.google.com/u/0/';
  }

  Ferdium.injectCSS(`${GOOGLE_CALENDAR_ASSET_BASE}/calendar.css`);

  Ferdium.handleDarkMode(isEnabled => {
    const cssId = 'cssDarkModeWorkaround';

    if (isEnabled) {
      if (!document.querySelector(`#${cssId}`)) {
        const head = document.querySelectorAll('head')[0];
        const link = document.createElement('link');
        link.id = cssId;
        link.rel = 'stylesheet';
        link.type = 'text/css';
        link.href = `${GOOGLE_CALENDAR_ASSET_BASE}/darkmode.css`;
        link.media = 'all';
        head.append(link);
      }
    } else {
      document.querySelector(`#${cssId}`)?.remove();
    }
  });
};
