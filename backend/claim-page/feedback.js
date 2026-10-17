// backend/claim-page/feedback.js
//
// Post-download panel for the claim page: a Google review link and an
// optional private feedback form. Imported by index.html; no build step.
//
// Two separate paths, and neither gates the guest's media:
//
// 1. Google review. Shown to every guest whenever GOOGLE_REVIEW_URL (set in
//    index.html) is a valid Google review link, and hidden entirely when it
//    isn't. It is rendered once, before the form, from the URL alone; no
//    rating, tag, or comment handler ever reads or changes it. There is no
//    review gating here and there must never be.
// 2. Private feedback, sent to submit-feedback. Everything is optional for
//    the guest; the endpoint only needs a star rating if they do send it.

// Must match FEEDBACK_CATEGORIES in supabase/functions/_shared/feedback.ts.
export const FEEDBACK_CATEGORIES = [
  { value: "photo_quality", label: "Photo quality" },
  { value: "ai_effects", label: "AI effects" },
  { value: "qr_delivery", label: "QR delivery" },
  { value: "print_experience", label: "Print experience" },
  { value: "ease_of_use", label: "Ease of use" },
  { value: "something_went_wrong", label: "Something went wrong" },
];

export const MAX_COMMENT_LENGTH = 1000;

// Hosts Google issues review links on: g.page/r/<id>/review and
// search.google.com/local/writereview?placeid=<id> are the direct forms;
// the others appear when a link is copied from Maps or Search.
const GOOGLE_REVIEW_HOSTS = new Set([
  "g.page",
  "search.google.com",
  "www.google.com",
  "google.com",
  "maps.google.com",
  "maps.app.goo.gl",
]);

/**
 * Returns the URL to link to, or null if `raw` isn't a usable Google review
 * link (empty, not https, not a Google host, or still a template value).
 * Null means the Google section isn't rendered at all.
 */
export function googleReviewHref(raw) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed || /YOUR|PLACEHOLDER|REPLACE|[<>{}]/i.test(trimmed)) return null;
  let url;
  try {
    url = new URL(trimmed);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" || !GOOGLE_REVIEW_HOSTS.has(url.hostname)) return null;
  if (url.pathname === "/" && !url.search) return null;
  return url.href;
}

/** The exact body sent to submit-feedback. Consent is false unless ticked. */
export function buildFeedbackPayload(claimToken, { rating, categories = [], comment = "", consent = false }) {
  const trimmed = typeof comment === "string" ? comment.trim() : "";
  return {
    claimToken,
    rating,
    categories: [...categories],
    comment: trimmed || undefined,
    consentToAnonymousTestimonial: consent === true,
  };
}

function el(doc, tag, { className, text, attrs } = {}) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  for (const [name, value] of Object.entries(attrs ?? {})) node.setAttribute(name, value);
  return node;
}

function visuallyHidden(doc, text) {
  return el(doc, "span", { className: "fb-sr", text });
}

/**
 * Builds the panel. `submit(payload)` must resolve to { status } (the HTTP
 * status) or reject on network failure; index.html passes a fetch wrapper.
 */
export function renderFeedbackPanel(doc, { googleReviewUrl, claimToken, submit }) {
  const panel = el(doc, "section", { className: "fb-panel", attrs: { "aria-label": "Share your experience" } });

  const reviewHref = googleReviewHref(googleReviewUrl);
  if (reviewHref) {
    const google = el(doc, "div", { className: "fb-google" });
    google.appendChild(el(doc, "h2", { className: "fb-heading", text: "Share your experience on Google" }));
    const link = el(doc, "a", {
      className: "fb-google-link",
      attrs: { href: reviewHref, target: "_blank", rel: "noopener noreferrer" },
    });
    link.appendChild(el(doc, "span", { text: "★", attrs: { "aria-hidden": "true" } }));
    link.appendChild(doc.createTextNode(" Leave a Google Review"));
    link.appendChild(visuallyHidden(doc, " (opens Google in a new tab)"));
    google.appendChild(link);
    panel.appendChild(google);
  }

  // "Not now" drops the form; with no Google link left, the whole panel goes.
  const form = renderFeedbackForm(doc, {
    claimToken,
    submit,
    onDismiss: () => (reviewHref ? form.remove() : panel.remove()),
  });
  panel.appendChild(form);
  return panel;
}

function renderFeedbackForm(doc, { claimToken, submit, onDismiss }) {
  const section = el(doc, "div", { className: "fb-feedback" });
  section.appendChild(el(doc, "h2", { className: "fb-heading", text: "Help us improve the Photo Booth" }));

  const form = el(doc, "form", { className: "fb-form", attrs: { novalidate: "" } });
  section.appendChild(form);

  // Star rating: a native radio group, so arrow keys, Tab, and screen
  // readers work without custom key handling. Filled vs outline stars plus
  // the "N of 5" text mean the choice never depends on color alone.
  let rating = 0;
  const ratingSet = el(doc, "fieldset", { className: "fb-fieldset" });
  ratingSet.appendChild(el(doc, "legend", { className: "fb-legend", text: "How was your experience?" }));
  const stars = el(doc, "div", { className: "fb-stars" });
  const glyphs = [];
  const radios = [];
  for (let value = 1; value <= 5; value += 1) {
    const label = el(doc, "label", { className: "fb-star" });
    const input = el(doc, "input", { className: "fb-sr-input" });
    input.type = "radio";
    input.name = "fb-rating";
    input.value = String(value);
    const glyph = el(doc, "span", { text: "☆", attrs: { "aria-hidden": "true" } });
    label.appendChild(input);
    label.appendChild(glyph);
    label.appendChild(visuallyHidden(doc, `${value} out of 5`));
    stars.appendChild(label);
    glyphs.push(glyph);
    radios.push(input);
    input.addEventListener("change", () => {
      rating = value;
      glyphs.forEach((g, i) => { g.textContent = i < value ? "★" : "☆"; });
      ratingStatus.textContent = `${value} out of 5`;
      error.textContent = "";
    });
  }
  ratingSet.appendChild(stars);
  const ratingStatus = el(doc, "p", { className: "fb-hint", text: "No rating yet", attrs: { "aria-live": "polite" } });
  ratingSet.appendChild(ratingStatus);
  form.appendChild(ratingSet);

  // Tags: checkboxes styled as chips; a check mark shows the selected state.
  const tagSet = el(doc, "fieldset", { className: "fb-fieldset" });
  tagSet.appendChild(el(doc, "legend", { className: "fb-legend", text: "What stood out?" }));
  const chips = el(doc, "div", { className: "fb-chips" });
  const tagInputs = [];
  for (const category of FEEDBACK_CATEGORIES) {
    const label = el(doc, "label", { className: "fb-chip" });
    const input = el(doc, "input", { className: "fb-sr-input" });
    input.type = "checkbox";
    input.name = "fb-category";
    input.value = category.value;
    label.appendChild(input);
    label.appendChild(el(doc, "span", { text: category.label }));
    chips.appendChild(label);
    tagInputs.push(input);
  }
  tagSet.appendChild(chips);
  form.appendChild(tagSet);

  const commentLabel = el(doc, "label", { className: "fb-legend", attrs: { for: "fb-comment" } });
  commentLabel.appendChild(doc.createTextNode("Anything we should improve? "));
  commentLabel.appendChild(el(doc, "span", { className: "fb-optional", text: "(optional)" }));
  form.appendChild(commentLabel);
  const comment = el(doc, "textarea", {
    className: "fb-comment",
    attrs: { id: "fb-comment", rows: "3", maxlength: String(MAX_COMMENT_LENGTH), "aria-describedby": "fb-comment-count" },
  });
  form.appendChild(comment);
  const count = el(doc, "p", { className: "fb-hint fb-count", text: `0 / ${MAX_COMMENT_LENGTH}`, attrs: { id: "fb-comment-count" } });
  comment.addEventListener("input", () => {
    count.textContent = `${[...comment.value].length} / ${MAX_COMMENT_LENGTH}`;
  });
  form.appendChild(count);

  const consentLabel = el(doc, "label", { className: "fb-consent" });
  const consent = el(doc, "input", { className: "fb-checkbox", attrs: { "aria-describedby": "fb-consent-note" } });
  consent.type = "checkbox";
  consent.checked = false;
  consentLabel.appendChild(consent);
  consentLabel.appendChild(el(doc, "span", {
    text: "Pacific Horizon Labs may quote my feedback as an anonymous testimonial.",
  }));
  form.appendChild(consentLabel);
  form.appendChild(el(doc, "p", {
    className: "fb-hint fb-consent-note",
    text: "Only your words would be quoted, without your name, photos, or event details.",
    attrs: { id: "fb-consent-note" },
  }));

  const error = el(doc, "p", { className: "fb-error", attrs: { role: "alert" } });
  form.appendChild(error);

  const send = el(doc, "button", { className: "fb-send", text: "Send Feedback" });
  send.type = "submit";
  form.appendChild(send);

  const notNow = el(doc, "button", { className: "fb-not-now", text: "Not now" });
  notNow.type = "button";
  notNow.addEventListener("click", onDismiss);
  form.appendChild(notNow);

  const finish = (message) => {
    const done = el(doc, "p", { className: "fb-done", text: message, attrs: { role: "status", tabindex: "-1" } });
    form.replaceWith(done);
    done.focus?.();
  };

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (rating < 1) {
      error.textContent = "Choose a star rating to send feedback.";
      radios[0].focus?.();
      return;
    }
    error.textContent = "";
    send.disabled = true;
    send.textContent = "Sending…";
    const payload = buildFeedbackPayload(claimToken, {
      rating,
      categories: tagInputs.filter((input) => input.checked).map((input) => input.value),
      comment: comment.value,
      consent: consent.checked,
    });
    try {
      const { status } = await submit(payload);
      if (status === 201) return finish("Thank you — your feedback helps us improve the Photo Booth.");
      if (status === 409) return finish("Feedback already received. Thank you.");
      if (status === 404 || status === 410) return finish("This link can no longer take feedback.");
      throw new Error(`Unexpected status ${status}`);
    } catch {
      error.textContent = "Couldn’t send your feedback. Please try again.";
      send.disabled = false;
      send.textContent = "Send Feedback";
    }
  });

  return section;
}
