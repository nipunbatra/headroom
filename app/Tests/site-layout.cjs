// Run against a served copy of the Pages bundle with Chrome installed.
const assert = require("node:assert/strict");
const { chromium } = require("playwright-core");

async function check(url) {
  const browser = await chromium.launch({ channel: "chrome" });
  try {
    const page = await browser.newPage();
    await page.goto(url);
    for (const [width, height] of [[1280, 720], [880, 560], [375, 812], [320, 568]]) {
      await page.setViewportSize({ width, height });
      const previews = page.getByRole("group", { name: "Screenshots" }).getByRole("button");
      assert.equal(await previews.count(), 4);
      for (const button of await previews.all()) {
        await button.focus();
        await page.keyboard.press("Enter");
        assert.equal(await button.getAttribute("aria-pressed"), "true");
        await page.locator("#preview").evaluate(image => image.decode());
        const layout = await page.evaluate(() => {
          const image = document.querySelector("#preview");
          return {
            width: document.documentElement.scrollWidth,
            height: document.documentElement.scrollHeight,
            fullSize: document.querySelector("#full").href === image.src && image.alt.length > 0,
            diskImage: document.querySelector(".download").pathname.endsWith("/Headroom.dmg")
          };
        });
        assert.ok(layout.width <= width && layout.height <= height, "Page overflows at " + width + " × " + height);
        assert.ok(layout.fullSize && layout.diskImage);
      }
      console.log("All four previews and the download fit at " + width + " × " + height);
    }
  } finally {
    await browser.close();
  }
}

check(process.argv[2]).catch(error => { console.error(error); process.exitCode = 1; });
