//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

// Toolbar button: hand the page URL to the native handler. The app downloads the page
// itself and opens the quick panel with it attached, so no page content crosses processes.
browser.action.onClicked.addListener((tab) => {
    if (tab && tab.url && /^https?:/i.test(tab.url)) {
        browser.runtime.sendNativeMessage("application.id", { url: tab.url });
    }
});
