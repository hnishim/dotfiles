module.exports = (config, Ferdium) => {
  // 日付指定があるURL用の正規表現
  const urlRegex = /\/calendar\/u\/\d+\/r\/(day|week|month|year|custom|agenda)\/(\d{4})\/(\d{1,2})\/(\d{1,2})/;
  let isProcessing = false;

  // 初期表示（日付なし）のときにDOMから現在表示されている日付を取得するフォールバック
  function getDateFromDOM() {
    try {
      // Google Calendarの「Mini Calendar（左上の月表示）」またはメインビューのデータ属性などから取得を試みる
      // 最も確実なのは、カレンダーが内部で保持しているか、DOMの grid に埋め込まれている日付
      const activeCell = document.querySelector('[data-date]');
      if (activeCell) {
        const dateStr = activeCell.getAttribute('data-date'); // "20260624" のような形式
        if (dateStr && dateStr.length === 8) {
          return {
            view: 'month', // デフォルトビューの仮定
            year: dateStr.substring(0, 4),
            month: String(parseInt(dateStr.substring(4, 6), 10)),
            day: String(parseInt(dateStr.substring(6, 8), 10))
          };
        }
      }
    } catch (e) {
      // 取得失敗時はnullを返す
    }
    return null;
  }

  function getCalendarState(url) {
    const match = url.match(urlRegex);
    if (match) {
      return {
        view: match[1],
        year: match[2],
        month: match[3],
        day: match[4]
      };
    }
    // URLから取れない場合はDOMからフォールバック試行
    return getDateFromDOM();
  }

  // webview.js経由で他タブの変更を検知した時の処理
  window.addEventListener('ferdium_gcal_receive_state', (event) => {
    const data = event.detail;
    if (!data) return;

    const currentState = getCalendarState(window.location.href);

    // 現在の状態が完全にパースできている場合のみ重複チェックを行う
    if (currentState) {
      if (currentState.view === data.view &&
          currentState.year === data.year &&
          currentState.month === data.month &&
          currentState.day === data.day) {
        return;
      }
    }

    console.log("[GCal Sync] 同期要求を受信。遷移を実行します:", data);
    isProcessing = true;
    
    // URLに日付が含まれていない（初期状態 /r のまま）ケースを考慮した置換処理
    let newUrl = window.location.href;
    if (urlRegex.test(newUrl)) {
      newUrl = newUrl.replace(
        /\/calendar\/u\/(\d+)\/r\/.+/,
        `/calendar/u/$1/r/${data.view}/${data.year}/${data.month}/${data.day}`
      );
    } else {
      newUrl = newUrl.replace(
        /\/calendar\/u\/(\d+)\/r\/?$/,
        `/calendar/u/$1/r/${data.view}/${data.year}/${data.month}/${data.day}`
      );
    }

    window.location.replace(newUrl);
  });

  // 自身のURL変更を監視
  let lastUrl = window.location.href;
  setInterval(() => {
    const currentUrl = window.location.href;
    if (currentUrl === lastUrl) return;
    lastUrl = currentUrl;

    if (isProcessing) {
      isProcessing = false;
      return;
    }

    // URLから直接判別できるときのみ外部へ通知（DOMフォールバックによる意図しないループを防ぐため）
    const match = currentUrl.match(urlRegex);
    if (!match) return;

    const state = {
      view: match[1],
      year: match[2],
      month: match[3],
      day: match[4]
    };

    console.log("[GCal Sync] 自身の日付変更を検知。ファイル書き込みを要求します:", state);
    
    const customEvent = new CustomEvent('ferdium_gcal_send_state', { detail: state });
    window.dispatchEvent(customEvent);
  }, 500);

  // 「週末を表示する」をトグルする関数
  function toggleWeekendVisibility() {
    const menuItems = document.querySelectorAll('[role="menuitemcheckbox"]');
    let weekendItem = null;

    // 日英両方の表記に対応
    const targetLabels = ['週末を表示する', 'Show weekends'];

    for (const item of menuItems) {
      const text = item.textContent || item.innerText || '';
      if (targetLabels.some(label => text.includes(label))) {
        weekendItem = item;
        break;
      }
    }

    if (weekendItem) {
      console.log("[GCal Sync] 週末の表示/非表示を切り替えます");
      weekendItem.click();
    } else {
      console.log("[GCal Sync] 「週末を表示する / Show weekends」のメニュー要素が見つかりませんでした");
    }
  }

  // キーボードショートカットのリスナー登録
  window.addEventListener('keydown', (event) => {
    const target = event.target;
    if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
      return;
    }

    // 'o' キーで実行
    if (event.key.toLowerCase() === 'o' && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      toggleWeekendVisibility();
    }
  }, true);
};
