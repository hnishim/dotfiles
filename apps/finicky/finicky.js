// URLの部分一致条件とルール順をZen側の設定から引き継ぎます。
const containsAny = (fragments) => (url) =>
  fragments.some((fragment) => url.href.includes(fragment));
const zenSpace = (name) => (url) => ({
  name: "Zen",
  args: ["-n", "--args", "--space", name, url.href],
});
const notionPersonal = /notion\.(?:so|com)\/hnishim/;
const notionMolcure  = /notion\.(?:so|com)\/p\/molcure/;

export default {
  // Zenの未一致URLは、これまでどおり直近のワークスペースで開きます。
  defaultBrowser: "Zen",
  handlers: [
    // Personal
    {
      match: containsAny([
        "twitter.com/",
        "https://x.com/",
        "amazon.co.jp/",
        "saisoncard.co.jp/",
        "jcb.co.jp/",
        "aplus.co.jp/",
        "topcard.co.jp/",
        "jal.co.jp/",
        "ana.co.jp/",
        "smbc-card.co.jp/",
        "offers-exchange.co.jp/",
        "netbk.co.jp/",
        "www.linkedin.com/",
        "8card.net/",
        "sbishinseibank.co.jp/",
        "sbisec.co.jp/",
        "monex.co.jp/",
        "kabu.co.jp/",
        "connect-sec.co.jp/",
        "coincheck.com/",
        "sbivc.co.jp/",
        "benefit401k.com/",
        "etrade.com/",
        "atwork.morganstanley.com/",
      ]),
      browser: zenSpace("Personal"),
    },
    { match: notionPersonal, browser: zenSpace("Personal") },

    // MOLCURE
    {
      match: containsAny([
        "jobcan.jp/",
        "tjg.account.box.com/",
        "axcelead.box.com/",
        "booking.elsi.jp/",
      ]),
      browser: zenSpace("MOLCURE"),
    },
    { match: notionMolcure, browser: zenSpace("MOLCURE") },

    // Shiftを押しながら開いたGoogle MeetはZenの既定動作へ。
    {
      match: (url) =>
        url.href.includes("meet.google.com") && finicky.getModifierKeys().shift,
      browser: "Zen",
    },

    // H2O
    {
      match: containsAny([
        "nulab.com/",
        "backlog.com/",
        "chat.google.com/",
        "meet.google.com/",
        "workhub.site/",
        "h2obox.app.box.com/",
      ]),
      browser: zenSpace("H2O"),
    },
  ],
};
