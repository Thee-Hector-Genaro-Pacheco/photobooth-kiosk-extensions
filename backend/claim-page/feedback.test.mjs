// backend/claim-page/feedback.test.mjs
//
// Claim-page feedback panel: Google review visibility and the payload sent
// to submit-feedback. Uses a minimal fake DOM, so no browser or packages.
//
// Run with: node --test backend/claim-page/feedback.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";
import { buildFeedbackPayload, googleReviewHref, renderFeedbackPanel } from "./feedback.js";

class FakeNode {
  constructor(tag) {
    this.tagName = tag;
    this.children = [];
    this.parent = null;
    this.attributes = {};
    this.listeners = {};
    this.textContentValue = "";
    this.className = "";
  }
  get textContent() {
    return this.textContentValue + this.children.map((child) => child.textContent).join("");
  }
  set textContent(value) {
    this.children = [];
    this.textContentValue = String(value);
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  appendChild(child) { child.parent = this; this.children.push(child); return child; }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  replaceWith(node) {
    const siblings = this.parent.children;
    siblings[siblings.indexOf(this)] = node;
    node.parent = this.parent;
    this.parent = null;
  }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  async dispatch(type) {
    const event = { preventDefault() {} };
    for (const fn of this.listeners[type] ?? []) await fn(event);
  }
}

const fakeDocument = {
  createElement: (tag) => new FakeNode(tag),
  createTextNode: (text) => { const node = new FakeNode("#text"); node.textContentValue = text; return node; },
};

function findAll(root, predicate, found = []) {
  if (predicate(root)) found.push(root);
  for (const child of root.children) findAll(child, predicate, found);
  return found;
}
const byClass = (root, name) => findAll(root, (n) => n.className.split(" ").includes(name));
const googleLinks = (root) => byClass(root, "fb-google-link");

const REVIEW_URL = "https://g.page/r/CExample123/review";

function render(googleReviewUrl, submit = async () => ({ status: 201 })) {
  return renderFeedbackPanel(fakeDocument, { googleReviewUrl, claimToken: "token", submit });
}

test("googleReviewHref accepts real Google review link shapes", () => {
  assert.equal(googleReviewHref(REVIEW_URL), REVIEW_URL);
  assert.equal(
    googleReviewHref("https://search.google.com/local/writereview?placeid=ChIJExample"),
    "https://search.google.com/local/writereview?placeid=ChIJExample",
  );
});

test("googleReviewHref fails safe on empty, placeholder, non-https, or non-Google values", () => {
  for (const value of [
    "",
    "   ",
    undefined,
    null,
    "https://g.page/r/YOUR-PLACE-ID/review",
    "https://g.page/r/<id>/review",
    "http://g.page/r/CExample123/review",
    "https://example.com/review",
    "https://g.page.evil.example/r/x/review",
    "https://www.google.com/",
    "javascript:alert(1)",
    "not a url",
  ]) {
    assert.equal(googleReviewHref(value), null, String(value));
  }
});

test("Google review link is hidden when no URL is configured, form still shows", () => {
  const panel = render("");
  assert.equal(googleLinks(panel).length, 0);
  assert.equal(byClass(panel, "fb-form").length, 1);
});

test("Google review visibility does not depend on the private rating", async () => {
  for (const chosen of [1, 2, 3, 4, 5]) {
    const panel = render(REVIEW_URL);
    const radios = findAll(panel, (n) => n.name === "fb-rating");
    assert.equal(googleLinks(panel).length, 1, "shown before any rating");

    await radios[chosen - 1].dispatch("change");
    const [link] = googleLinks(panel);
    assert.ok(link, `still shown after a ${chosen}-star rating`);
    assert.equal(link.getAttribute("href"), REVIEW_URL);

    // Submitting, including a low rating, leaves it in place too.
    await byClass(panel, "fb-form")[0].dispatch("submit");
    assert.equal(googleLinks(panel).length, 1, `still shown after submitting ${chosen} stars`);
  }
});

test("Google review link uses neutral copy and opens safely", () => {
  const panel = render(REVIEW_URL);
  const [link] = googleLinks(panel);
  assert.match(panel.textContent, /Share your experience on Google/);
  assert.match(link.textContent, /Leave a Google Review/);
  assert.doesNotMatch(byClass(panel, "fb-google")[0].textContent, /star|rating|reward|free/i);
  assert.equal(link.getAttribute("target"), "_blank");
  assert.equal(link.getAttribute("rel"), "noopener noreferrer");
});

test("testimonial consent checkbox starts unchecked and payload defaults to false", async () => {
  const panel = render("");
  const [consent] = findAll(panel, (n) => n.className === "fb-checkbox");
  assert.equal(consent.checked, false);

  assert.equal(buildFeedbackPayload("t", { rating: 5 }).consentToAnonymousTestimonial, false);
  assert.equal(buildFeedbackPayload("t", { rating: 5, consent: "yes" }).consentToAnonymousTestimonial, false);
  assert.equal(buildFeedbackPayload("t", { rating: 5, consent: true }).consentToAnonymousTestimonial, true);
});

test("submitting sends only public fields, with the chosen rating, tags, and comment", async () => {
  const sent = [];
  const panel = render("", async (payload) => { sent.push(payload); return { status: 201 }; });
  await findAll(panel, (n) => n.name === "fb-rating")[2].dispatch("change");
  const tags = findAll(panel, (n) => n.name === "fb-category");
  tags[0].checked = true;
  tags[2].checked = true;
  byClass(panel, "fb-comment")[0].value = "  Faster QR please  ";

  await byClass(panel, "fb-form")[0].dispatch("submit");
  assert.deepEqual(sent, [{
    claimToken: "token",
    rating: 3,
    categories: ["photo_quality", "qr_delivery"],
    comment: "Faster QR please",
    consentToAnonymousTestimonial: false,
  }]);
  assert.match(panel.textContent, /your feedback helps us improve the Photo Booth/);
});

test("submitting without a rating asks for one and sends nothing", async () => {
  const sent = [];
  const panel = render("", async (payload) => { sent.push(payload); return { status: 201 }; });
  await byClass(panel, "fb-form")[0].dispatch("submit");
  assert.equal(sent.length, 0);
  assert.match(byClass(panel, "fb-error")[0].textContent, /star rating/);
});

test("a duplicate submit (409) is shown as already received, not as an error", async () => {
  const panel = render("", async () => ({ status: 409 }));
  await findAll(panel, (n) => n.name === "fb-rating")[4].dispatch("change");
  await byClass(panel, "fb-form")[0].dispatch("submit");
  assert.match(panel.textContent, /Feedback already received\. Thank you\./);
  assert.equal(byClass(panel, "fb-error").length, 0);
});

test("star controls are labelled N out of 5", () => {
  const panel = render("");
  const labels = byClass(panel, "fb-star").map((star) => byClass(star, "fb-sr")[0].textContent);
  assert.deepEqual(labels, ["1 out of 5", "2 out of 5", "3 out of 5", "4 out of 5", "5 out of 5"]);
});

test("network and server failures show a short retry message and keep the form", async () => {
  for (const submit of [async () => { throw new TypeError("Failed to fetch"); }, async () => ({ status: 500 })]) {
    const panel = render("", submit);
    await findAll(panel, (n) => n.name === "fb-rating")[2].dispatch("change");
    await byClass(panel, "fb-form")[0].dispatch("submit");
    assert.equal(byClass(panel, "fb-error")[0].textContent, "Couldn’t send your feedback. Please try again.");
    assert.equal(byClass(panel, "fb-form").length, 1);
    assert.equal(byClass(panel, "fb-send")[0].disabled, false);
  }
});

test("Not now removes the form and keeps the Google link", async () => {
  const panel = render(REVIEW_URL);
  await byClass(panel, "fb-not-now")[0].dispatch("click");
  assert.equal(byClass(panel, "fb-form").length, 0);
  assert.equal(googleLinks(panel).length, 1);
});

test("Not now with no Google link removes the whole panel", async () => {
  const content = new FakeNode("div");
  const panel = content.appendChild(render(""));
  await byClass(panel, "fb-not-now")[0].dispatch("click");
  assert.equal(content.children.length, 0);
});
