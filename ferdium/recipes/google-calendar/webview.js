// GoogleのTrusted TypesによるinnerHTML・インジェクション制限を回避
if (window.trustedTypes && window.trustedTypes.createPolicy) {
  if (!window.trustedTypes.defaultPolicy) {
    window.trustedTypes.createPolicy('default', {
      createHTML: (string) => string,
      createScript: (string) => string,
      createScriptURL: (string) => string,
    });
  }
}

function _interopRequireDefault(obj) {
  return obj && obj.__esModule ? obj : { default: obj };
}

const _path = _interopRequireDefault(require('path'));
const fs = require('fs');
const os = require('os');

// タブ間で共有する一時ファイルのパス
const syncFilePath = _path.default.join(os.tmpdir(), 'ferdium_gcal_sync.json');

module.exports = Ferdium => {
  // 自身のタブを識別する一意のID
  const myTabId = Math.random().toString(36).substring(2, 9);

  // user.jsからの書き込み要求をフックしてファイルに保存
  window.addEventListener('ferdium_gcal_send_state', (event) => {
    const state = event.detail;
    state.senderId = myTabId;
    state.timestamp = Date.now();
    try {
      fs.writeFileSync(syncFilePath, JSON.stringify(state), 'utf8');
    } catch (err) {
      // 権限エラー等の対策
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

      // 他のタブが3秒以内に書き込んだデータであればuser.jsへ通知
      if (data && data.senderId !== myTabId && (Date.now() - data.timestamp < 3000)) {
        const customEvent = new CustomEvent('ferdium_gcal_receive_state', { detail: data });
        window.dispatchEvent(customEvent);
      }
    } catch (err) {
      // エラーは黙殺
    }
  }, 400);

  if (
    location.hostname === 'workspace.google.com' &&
    location.href.includes('products/calendar/')
  ) {
    location.href =
      'https://accounts.google.com/AccountChooser?continue=https://calendar.google.com/u/0/';
  }

  Ferdium.injectCSS(_path.default.join(__dirname, 'service.css'));
  Ferdium.injectCSS(
    'https://cdn.statically.io/gh/ferdium/ferdium-recipes/main/recipes/google-calendar/calendar.css',
  );
  Ferdium.injectJSUnsafe(
    'https://cdn.statically.io/gh/ferdium/ferdium-recipes/main/recipes/google-calendar/webview-unsave.js',
  );

  Ferdium.handleDarkMode(isEnabled => {
    const cssId = 'cssDarkModeWorkaround';

    if (isEnabled) {
      if (!document.querySelector(`#${cssId}`)) {
        const head = document.querySelectorAll('head')[0];
        const link = document.createElement('link');
        link.id = cssId;
        link.rel = 'stylesheet';
        link.type = 'text/css';
        link.href =
          'https://cdn.statically.io/gh/ferdium/ferdium-recipes/main/recipes/google-calendar/darkmode.css';
        link.media = 'all';
        head.append(link);
      }
    } else {
      document.querySelector(`#${cssId}`)?.remove();
    }
  });
};
