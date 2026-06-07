// Injects an EN / 中文 toggle into the mdBook menu bar.
//
// The two language books are deployed side by side (…/en/… and …/zh/…) with an
// identical chapter file layout, so switching language is a pure path swap that
// keeps the reader on the same page. The current language is read from the
// <html lang> attribute that mdBook stamps from each book's `book.toml`.
(function () {
  "use strict";

  var GLOBE =
    '<span class="fa-svg" aria-hidden="true">' +
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" ' +
    'fill="none" stroke="currentColor" stroke-width="2" ' +
    'stroke-linecap="round" stroke-linejoin="round">' +
    '<circle cx="12" cy="12" r="9"></circle>' +
    '<path d="M3 12h18"></path>' +
    '<path d="M12 3c2.6 2.7 4 5.8 4 9s-1.4 6.3-4 9c-2.6-2.7-4-5.8-4-9s1.4-6.3 4-9z"></path>' +
    "</svg></span>";

  function targetHref(current, other) {
    var marker = "/" + current + "/";
    var path = window.location.pathname;
    var idx = path.lastIndexOf(marker);
    var dest;
    if (idx !== -1) {
      dest = path.slice(0, idx) + "/" + other + "/" + path.slice(idx + marker.length);
    } else {
      // Local `mdbook serve` (single book served at /) — best-effort fallback.
      dest = "../" + other + "/index.html";
    }
    return dest + (window.location.hash || "");
  }

  function build() {
    var current = document.documentElement.lang === "zh" ? "zh" : "en";
    var other = current === "en" ? "zh" : "en";
    var label = current === "en" ? "中文" : "EN";
    var title = current === "en" ? "切换到简体中文" : "Switch to English";

    var link = document.createElement("a");
    link.className = "language-toggle";
    link.href = targetHref(current, other);
    link.title = title;
    link.setAttribute("aria-label", title);
    link.innerHTML = GLOBE + '<span class="lang-label">' + label + "</span>";

    var right = document.querySelector("#mdbook-menu-bar .right-buttons") ||
      document.querySelector(".right-buttons");
    if (right) {
      right.insertBefore(link, right.firstChild);
      return;
    }
    var bar = document.querySelector("#mdbook-menu-bar") ||
      document.querySelector(".menu-bar");
    if (bar) {
      var holder = document.createElement("div");
      holder.className = "right-buttons";
      holder.appendChild(link);
      bar.appendChild(holder);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", build);
  } else {
    build();
  }
})();
