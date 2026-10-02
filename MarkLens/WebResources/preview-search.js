(() => {
    if (window.MarkLensSearch) {
        return;
    }

    const state = {
        term: "",
        hits: [],
        currentIndex: -1,
        activeStart: null,
        lastSelectionStart: null,
        lastSelectionText: null
    };

    function rootElement() {
        return document.getElementById("container") || document.body;
    }

    function folded(value) {
        return (value || "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
    }

    function buildFoldedMap(original) {
        const foldedChars = [];
        const foldedToCharIndex = [];
        const originalCharStarts = [];
        const originalCharLengths = [];
        let codeUnitIndex = 0;
        let charIndex = 0;

        for (const ch of original) {
            originalCharStarts.push(codeUnitIndex);
            originalCharLengths.push(ch.length);

            const normalized = folded(ch);
            for (let index = 0; index < normalized.length; index += 1) {
                foldedChars.push(normalized[index]);
                foldedToCharIndex.push(charIndex);
            }

            codeUnitIndex += ch.length;
            charIndex += 1;
        }

        return {
            folded: foldedChars.join(""),
            foldedToCharIndex,
            originalCharStarts,
            originalCharLengths
        };
    }

    function shouldSkipTextNode(node) {
        let element = node.parentElement;
        while (element) {
            const tagName = element.tagName;
            if (tagName === "SCRIPT" || tagName === "STYLE" || tagName === "TEXTAREA") {
                return true;
            }
            if (
                element.classList.contains("copy-btn") ||
                element.classList.contains("sr-only") ||
                element.classList.contains("search-hit")
            ) {
                return true;
            }
            element = element.parentElement;
        }
        return false;
    }

    function documentOffsetForTextNodePosition(targetNode, targetOffset) {
        const root = rootElement();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let absoluteOffset = 0;
        let node;

        while ((node = walker.nextNode())) {
            const text = node.nodeValue || "";
            if (node === targetNode) {
                return absoluteOffset + Math.min(targetOffset, text.length);
            }
            absoluteOffset += text.length;
        }

        return null;
    }

    function documentOffsetForRangeStart(range) {
        const root = rootElement();
        const start = range.startContainer;
        if (!root.contains(start)) {
            return null;
        }

        try {
            const prefix = document.createRange();
            prefix.selectNodeContents(root);
            prefix.setEnd(start, range.startOffset);
            return prefix.toString().length;
        } catch (_) {
            return documentOffsetForTextNodePosition(start, range.startOffset);
        }
    }

    function selectedDocumentOffset() {
        const selection = window.getSelection();
        if (!selection || selection.rangeCount === 0) {
            return null;
        }

        const range = selection.getRangeAt(0);
        if (range.collapsed) {
            return null;
        }

        const root = rootElement();
        if (!root.contains(range.startContainer)) {
            return null;
        }

        return documentOffsetForRangeStart(range);
    }

    function captureSelectionAnchor() {
        const offset = selectedDocumentOffset();
        if (offset != null) {
            const selection = window.getSelection();
            state.lastSelectionStart = offset;
            state.lastSelectionText = selection ? selection.toString() : null;
        } else if (document.hasFocus()) {
            state.lastSelectionStart = null;
            state.lastSelectionText = null;
        }
        return offset;
    }

    function clearDocumentSelection() {
        const selection = window.getSelection();
        if (selection) {
            selection.removeAllRanges();
        }
    }

    function consumeSelectionAnchor() {
        const offset = captureSelectionAnchor();
        if (offset != null) {
            state.lastSelectionStart = null;
            state.lastSelectionText = null;
            clearDocumentSelection();
            return offset;
        }

        if (state.lastSelectionStart != null) {
            const cachedOffset = state.lastSelectionStart;
            state.lastSelectionStart = null;
            state.lastSelectionText = null;
            return cachedOffset;
        }

        return null;
    }

    function clearHighlights() {
        document.querySelectorAll(".search-hit").forEach(span => {
            const parent = span.parentNode;
            parent.replaceChild(document.createTextNode(span.textContent), span);
            parent.normalize();
        });
        state.hits = [];
        state.currentIndex = -1;
    }

    function positionAtDocumentOffset(offset) {
        const walker = document.createTreeWalker(rootElement(), NodeFilter.SHOW_TEXT);
        let absoluteOffset = 0;
        let node;

        while ((node = walker.nextNode())) {
            const length = (node.nodeValue || "").length;
            if (offset <= absoluteOffset + length) {
                return { node, offset: offset - absoluteOffset };
            }
            absoluteOffset += length;
        }

        return null;
    }

    function finishSearch() {
        const hit = state.hits[state.currentIndex];
        const start = hit ? hit.start : null;
        const end = hit ? hit.end : null;
        clearHighlights();
        state.term = "";
        state.activeStart = null;
        state.lastSelectionStart = null;
        state.lastSelectionText = null;

        if (start == null || end == null) {
            return result();
        }

        const startPosition = positionAtDocumentOffset(start);
        const endPosition = positionAtDocumentOffset(end);
        if (!startPosition || !endPosition) {
            return result();
        }

        const range = document.createRange();
        range.setStart(startPosition.node, startPosition.offset);
        range.setEnd(endPosition.node, endPosition.offset);
        const selection = window.getSelection();
        if (selection) {
            selection.removeAllRanges();
            selection.addRange(range);
        }
        return result();
    }

    function result() {
        return {
            count: state.hits.length,
            index: state.currentIndex >= 0 ? state.currentIndex + 1 : 0
        };
    }

    function resultWithSelection(searchResult, selection) {
        if (selection != null) {
            searchResult.selection = selection;
        }
        return searchResult;
    }

    function isInViewport(element) {
        const rect = element.getBoundingClientRect();
        return rect.top >= 0
            && rect.left >= 0
            && rect.bottom <= window.innerHeight
            && rect.right <= window.innerWidth;
    }

    function selectHit(index, shouldScroll = true, scrollBlock = "nearest") {
        if (index < 0 || index >= state.hits.length) {
            state.currentIndex = -1;
            state.activeStart = null;
            return result();
        }

        state.currentIndex = index;
        state.hits.forEach((hit, hitIndex) => {
            hit.elements.forEach(element => {
                element.classList.toggle("search-hit-active", hitIndex === index);
            });
        });

        const hit = state.hits[index];
        state.activeStart = hit.start;
        const firstElement = hit.elements[0];

        if (shouldScroll && firstElement && !isInViewport(firstElement)) {
            firstElement.scrollIntoView({
                behavior: "smooth",
                block: scrollBlock,
                inline: "nearest"
            });
        }

        return result();
    }

    function selectHitAtOrAfter(offset) {
        const nextIndex = state.hits.findIndex(hit => hit.start >= offset);
        return selectHit(nextIndex >= 0 ? nextIndex : 0, true);
    }

    function selectHitAtOrBefore(offset) {
        let previousIndex = -1;
        for (let index = state.hits.length - 1; index >= 0; index -= 1) {
            if (state.hits[index].start <= offset) {
                previousIndex = index;
                break;
            }
        }

        return selectHit(previousIndex >= 0 ? previousIndex : state.hits.length - 1, true);
    }

    function searchableContent() {
        const root = rootElement();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const segments = [];
        const foldedChars = [];
        const foldedLocations = [];
        let absoluteOffset = 0;
        let node;

        while ((node = walker.nextNode())) {
            const text = node.nodeValue || "";
            const nodeStart = absoluteOffset;
            absoluteOffset += text.length;

            if (shouldSkipTextNode(node) || !text.trim()) {
                continue;
            }

            const map = buildFoldedMap(text);
            const segmentIndex = segments.length;
            segments.push({
                node,
                text,
                nodeStart,
                ranges: []
            });

            for (let foldedIndex = 0; foldedIndex < map.folded.length; foldedIndex += 1) {
                const charIndex = map.foldedToCharIndex[foldedIndex];
                const startCU = map.originalCharStarts[charIndex];
                const endCU = startCU + map.originalCharLengths[charIndex];

                foldedChars.push(map.folded[foldedIndex]);
                foldedLocations.push({
                    segmentIndex,
                    startCU,
                    endCU,
                    documentStart: nodeStart + startCU,
                    documentEnd: nodeStart + endCU
                });
            }
        }

        return {
            folded: foldedChars.join(""),
            foldedLocations,
            segments
        };
    }

    function appendMatchRanges(segments, match, startLocation, endLocation) {
        for (let segmentIndex = startLocation.segmentIndex; segmentIndex <= endLocation.segmentIndex; segmentIndex += 1) {
            const segment = segments[segmentIndex];
            const startCU = segmentIndex === startLocation.segmentIndex ? startLocation.startCU : 0;
            const endCU = segmentIndex === endLocation.segmentIndex ? endLocation.endCU : segment.text.length;

            if (startCU < endCU) {
                segment.ranges.push({
                    startCU,
                    endCU,
                    match
                });
            }
        }
    }

    function applyRanges(segments) {
        for (const segment of segments) {
            if (segment.ranges.length === 0) {
                continue;
            }

            segment.ranges.sort((lhs, rhs) => rhs.startCU - lhs.startCU);

            for (const range of segment.ranges) {
                const node = segment.node;
                if (!node.parentNode) {
                    continue;
                }

                node.splitText(range.endCU);
                const matched = node.splitText(range.startCU);
                const span = document.createElement("span");
                span.className = "search-hit";
                span.dataset.searchStart = String(range.match.start);
                span.textContent = matched.nodeValue || "";

                matched.parentNode.replaceChild(span, matched);
                range.match.elements.push(span);
            }
        }

        state.hits.forEach(match => {
            match.elements.sort((lhs, rhs) => {
                return Number(lhs.dataset.searchStart) - Number(rhs.dataset.searchStart);
            });
        });
    }

    function rebuild(term, preferredStart) {
        clearHighlights();
        state.term = term || "";

        if (!state.term) {
            state.activeStart = null;
            return result();
        }

        const foldedTerm = folded(state.term);
        if (!foldedTerm) {
            state.activeStart = null;
            return result();
        }

        const escaped = foldedTerm.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const regex = new RegExp(escaped, "g");
        const content = searchableContent();
        let match;

        while ((match = regex.exec(content.folded))) {
            const foldedStart = match.index;
            const foldedEnd = foldedStart + match[0].length;
            const startLocation = content.foldedLocations[foldedStart];
            const endLocation = content.foldedLocations[foldedEnd - 1];

            if (startLocation && endLocation) {
                const searchMatch = {
                    start: startLocation.documentStart,
                    end: endLocation.documentEnd,
                    elements: []
                };

                state.hits.push(searchMatch);
                appendMatchRanges(content.segments, searchMatch, startLocation, endLocation);
            }

            if (match[0].length === 0) {
                regex.lastIndex += 1;
            }
        }

        applyRanges(content.segments);

        if (state.hits.length === 0) {
            state.activeStart = null;
            return result();
        }

        let selectedIndex = 0;
        if (preferredStart != null) {
            const exactIndex = state.hits.findIndex(hit => hit.start === preferredStart);
            if (exactIndex >= 0) {
                selectedIndex = exactIndex;
            } else {
                const nextIndex = state.hits.findIndex(hit => hit.start > preferredStart);
                selectedIndex = nextIndex >= 0 ? nextIndex : 0;
            }
        }

        return selectHit(selectedIndex, true, "nearest");
    }

    document.addEventListener("selectionchange", () => {
        captureSelectionAnchor();
    });

    window.MarkLensSearch = {
        run(payload) {
            payload = payload || {};
            const command = payload.command || "search";
            const term = payload.term || "";
            let selection = null;

            if (payload.includeSelection === true) {
                captureSelectionAnchor();
                selection = state.lastSelectionText || "";
            }

            if (command === "anchor") {
                const offset = captureSelectionAnchor();
                if (offset != null) {
                    state.activeStart = offset;
                }
                return resultWithSelection(result(), state.lastSelectionText || "");
            }

            if (command === "finish") {
                return finishSearch();
            }

            if (command === "search") {
                const offset = consumeSelectionAnchor();
                return resultWithSelection(rebuild(term, offset ?? state.activeStart), selection);
            }

            if (term !== state.term) {
                const offset = consumeSelectionAnchor();
                return resultWithSelection(rebuild(term, offset ?? state.activeStart), selection);
            }

            if (state.hits.length === 0) {
                return resultWithSelection(result(), selection);
            }

            const offset = consumeSelectionAnchor();
            if (offset != null) {
                const searchResult = command === "previous"
                    ? selectHitAtOrBefore(offset)
                    : selectHitAtOrAfter(offset);
                return resultWithSelection(searchResult, selection);
            }

            if (command === "previous") {
                const previousIndex = state.currentIndex <= 0 ? state.hits.length - 1 : state.currentIndex - 1;
                return resultWithSelection(selectHit(previousIndex, true), selection);
            }

            const nextIndex = state.currentIndex < 0
                ? 0
                : (state.currentIndex + 1) % state.hits.length;
            return resultWithSelection(selectHit(nextIndex, true), selection);
        },
        clear() {
            clearHighlights();
            state.term = "";
            state.activeStart = null;
            state.lastSelectionStart = null;
            state.lastSelectionText = null;
            return result();
        }
    };
})();
