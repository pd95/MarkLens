import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";

import { chromium } from "@playwright/test";

const toolsDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(toolsDirectory, "..");
const resourcesDirectory = join(
    repositoryRoot,
    "MarkdownPipeline",
    "Sources",
    "MarkdownPipeline",
    "Resources",
    "WebResources"
);
const inventory = JSON.parse(readFileSync(join(repositoryRoot, "WEB_DEPENDENCIES.json"), "utf8"));

function dependencyVersion(name) {
    const dependency = inventory.dependencies.find(item => item.name === name);
    assert(dependency, `Missing ${name} from WEB_DEPENDENCIES.json`);
    return dependency.version;
}

function testHighlightJS() {
    const script = readFileSync(join(resourcesDirectory, "highlight.min.js"), "utf8");
    const context = {};
    runInNewContext(script, context);
    assert(context.hljs, "highlight.js did not create the expected global");
    assert.equal(context.hljs.versionString, dependencyVersion("highlight.js"));

    const packagedLanguages = readdirSync(
        join(toolsDirectory, "node_modules", "@highlightjs", "cdn-assets", "languages")
    )
        .filter(name => name.endsWith(".min.js"))
        .map(name => name.replace(/\.min\.js$/, ""));
    const registeredLanguages = new Set(context.hljs.listLanguages());
    for (const language of packagedLanguages) {
        assert(registeredLanguages.has(language), `highlight.js did not register ${language}`);
    }

    const highlighted = context.hljs.highlight("let value = 1", {
        language: "swift",
        ignoreIllegals: true
    });
    assert.match(highlighted.value, /hljs-keyword/);
    const detected = context.hljs.highlightAuto("function greet(name) { return name; }");
    assert(detected.value.length > 0, "highlight.js auto-detection returned no markup");
}

function testKaTeX() {
    const script = readFileSync(join(resourcesDirectory, "katex.min.js"), "utf8");
    const context = {};
    runInNewContext(script, context);
    assert(context.katex, "KaTeX did not create the expected global");
    assert.equal(context.katex.version, dependencyVersion("KaTeX"));

    const markup = context.katex.renderToString("E = mc^2", {
        displayMode: true,
        output: "htmlAndMathml",
        throwOnError: true,
        trust: false
    });
    assert.match(markup, /class="katex-mathml"/);
    assert.match(markup, /class="katex-html"/);

    const unsafeLink = context.katex.renderToString("\\href{javascript:alert(1)}{bad}", {
        output: "htmlAndMathml",
        throwOnError: true,
        trust: false
    });
    assert.doesNotMatch(unsafeLink, /<a\b/i);
    assert.doesNotMatch(unsafeLink, /\shref=/i);
    const unsafeClass = context.katex.renderToString("\\htmlClass{evil}{x}", {
        output: "htmlAndMathml",
        throwOnError: true,
        trust: false
    });
    assert.doesNotMatch(unsafeClass, /class="evil"/i);

    const stylesheet = readFileSync(join(resourcesDirectory, "katex.min.css"), "utf8");
    const fontReferences = [...stylesheet.matchAll(/fonts\/(KaTeX_[^)"']+\.woff2)/g)]
        .map(match => match[1]);
    assert(fontReferences.length > 0, "KaTeX CSS contains no WOFF2 font references");
    for (const name of new Set(fontReferences)) {
        assert.doesNotThrow(
            () => readFileSync(join(resourcesDirectory, name)),
            `Missing KaTeX font ${name}`
        );
    }
}

async function testMermaid() {
    const mermaidScript = join(resourcesDirectory, "mermaid.min.js");
    const renderer = readFileSync(join(resourcesDirectory, "mermaid-renderer.js"), "utf8")
        .replaceAll("{{MERMAID_THEME}}", "light");
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        await page.setContent(`<!doctype html>
            <html><body>
                <div id="valid" class="mermaid-block" data-mermaid-diagram>
                    <pre class="mermaid-source"><code class="language-mermaid">flowchart LR
                        A[Start] --> B[Finish]
                        click A "javascript:alert(1)"
                    </code></pre>
                </div>
                <div id="invalid" class="mermaid-block" data-mermaid-diagram>
                    <pre class="mermaid-source"><code class="language-mermaid">not a valid diagram</code></pre>
                </div>
                <div id="sequence" class="mermaid-block" data-mermaid-diagram>
                    <pre class="mermaid-source"><code class="language-mermaid">sequenceDiagram
                        Alice->>Bob: Hello
                        Bob-->>Alice: Hi
                    </code></pre>
                </div>
            </body></html>`);
        await page.addScriptTag({ path: mermaidScript });
        await page.addScriptTag({ content: renderer });
        await page.evaluate(() => document.dispatchEvent(new Event("DOMContentLoaded")));
        await page.locator("#valid.is-rendered svg").waitFor();
        await page.locator("#sequence.is-rendered svg").waitFor();
        await page.locator("#invalid .mermaid-error").waitFor();
        assert.match(await page.locator("#sequence").textContent(), /Hello/);

        const safety = await page.locator(".mermaid-block").evaluateAll(blocks => ({
            executableScripts: blocks.reduce(
                (count, block) => count + block.querySelectorAll("script").length,
                0
            ),
            inlineHandlers: blocks.reduce(
                (count, block) => count
                    + [...block.querySelectorAll("*")].filter(element =>
                        [...element.attributes].some(attribute => attribute.name.startsWith("on"))
                    ).length,
                0
            ),
            unsafeLinks: blocks.reduce(
                (count, block) => count
                    + [...block.querySelectorAll("[href]")].filter(element =>
                        element.getAttribute("href")?.trim().toLowerCase().startsWith("javascript:")
                    ).length,
                0
            )
        }));
        assert.deepEqual(safety, {
            executableScripts: 0,
            inlineHandlers: 0,
            unsafeLinks: 0
        });
        assert.equal(
            await page.locator("#invalid code").textContent(),
            "not a valid diagram"
        );
    } finally {
        await browser.close();
    }
}

async function testCodeBlockLanguageBadges() {
    const stylesheet = readFileSync(join(resourcesDirectory, "markdown-style.css"), "utf8");
    const longSwiftCode = Array.from(
        { length: 80 },
        (_, index) => `let value${index} = ${index}`
    ).join("\n");
    const template = readFileSync(join(resourcesDirectory, "template.html"), "utf8")
        .replace("{{STYLES}}", `<style>${stylesheet}</style>`)
        .replace("{{THEME}}", "light")
        .replace("{{FILENAME}}", "Code block badge test")
        .replace("{{HTML}}", `
            <pre><code class="hljs language-swift"
                data-code-language="swift"
                data-code-language-source="explicit">${longSwiftCode}</code></pre>
            <pre><code class="hljs language-javascript"
                data-code-language="javascript"
                data-code-language-source="automatic">const value = 1;</code></pre>
            <pre><code class="lang-plaintext"
                data-code-language="plaintext"
                data-code-language-source="fallback">plain text</code></pre>
            <div style="height: 1000px"></div>
        `)
        .replace("{{SCRIPTS}}", "");
    const browser = await chromium.launch({ headless: true });
    try {
        const page = await browser.newPage();
        await page.emulateMedia({ colorScheme: "dark" });
        await page.setContent(template);

        assert.deepEqual(
            await page.locator(".code-language-badge").allTextContents(),
            ["Swift", "JavaScript", "Plain text"]
        );
        const accents = await page.locator(".code-language-badge").evaluateAll(badges =>
            badges.map(badge => ({
                color: badge.style.getPropertyValue("--code-language-color"),
                source: badge.dataset.languageColorSource,
                dotColor: getComputedStyle(badge, "::before").backgroundColor
            }))
        );
        assert.deepEqual(accents, [
            { color: "#f05138", source: "linguist", dotColor: "rgb(240, 81, 56)" },
            { color: "#f1e05a", source: "linguist", dotColor: "rgb(241, 224, 90)" },
            { color: "#8e8e93", source: "fallback", dotColor: "rgb(142, 142, 147)" }
        ]);
        const explicitLightAppearance = await page.locator(".code-block").first().evaluate(block => ({
            badgeBackground: getComputedStyle(block.querySelector(".code-language-badge")).backgroundColor,
            badgeBorderStyle: getComputedStyle(block.querySelector(".code-language-badge")).borderStyle,
            badgeShadow: getComputedStyle(block.querySelector(".code-language-badge")).boxShadow,
            bodyBackground: getComputedStyle(document.body).backgroundColor,
            codeBackground: getComputedStyle(block.querySelector("code")).backgroundColor
        }));
        assert.deepEqual(explicitLightAppearance, {
            badgeBackground: "rgba(0, 0, 0, 0)",
            badgeBorderStyle: "none",
            badgeShadow: "none",
            bodyBackground: "rgb(255, 255, 255)",
            codeBackground: "rgb(246, 246, 246)"
        });
        assert.equal(
            await page.locator(".code-language-badge").nth(1).getAttribute("aria-label"),
            "Automatically detected language: JavaScript"
        );
        assert.equal(await page.locator(".code-block-header").count(), 3);
        assert.equal(await page.locator(".code-block > .code-block-controls").count(), 3);
        await page.locator(".code-block").first().hover();
        await page.waitForTimeout(150);
        const layout = await page.locator(".code-block").first().evaluate(block => {
            const badgeBounds = block.querySelector(".code-language-badge").getBoundingClientRect();
            const controlsBounds = block.querySelector(".code-block-controls").getBoundingClientRect();
            const code = block.querySelector("code");
            return {
                controlsFollowBadge: badgeBounds.right <= controlsBounds.left,
                codeTopPadding: getComputedStyle(code).paddingTop,
                controlsOpacity: getComputedStyle(block.querySelector(".code-block-controls")).opacity
            };
        });
        assert.deepEqual(layout, {
            controlsFollowBadge: true,
            codeTopPadding: "44px",
            controlsOpacity: "1"
        });
        const initialPositions = await page.locator(".code-block").first().evaluate(block => ({
            badgeTop: block.querySelector(".code-language-badge").getBoundingClientRect().top,
            controlsTop: block.querySelector(".code-block-controls").getBoundingClientRect().top
        }));
        await page.evaluate(() => window.scrollTo(0, 200));
        const scrolledPositions = await page.locator(".code-block").first().evaluate(block => ({
            badgeTop: block.querySelector(".code-language-badge").getBoundingClientRect().top,
            controlsTop: block.querySelector(".code-block-controls").getBoundingClientRect().top
        }));
        assert(scrolledPositions.badgeTop < initialPositions.badgeTop - 100);
        assert.equal(scrolledPositions.controlsTop, 12);
    } finally {
        await browser.close();
    }
}

testHighlightJS();
testKaTeX();
await testCodeBlockLanguageBadges();
await testMermaid();
console.log("Web dependency smoke tests passed.");
