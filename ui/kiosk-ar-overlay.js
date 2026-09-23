/**
 * ui/kiosk-ar-overlay.js - Photobooth-App Live AR Face Overlay Runtime.
 *
 * Architectural Guarantees:
 * 1. Overlay is a separate transparent canvas layer above existing live preview.
 * 2. Does NOT read from or modify Photobooth-App's OffscreenCanvas or worker.
 * 3. Does NOT replace Photobooth-App's camera stream.
 * 4. pointer-events: none ensures zero interference with buttons, themes, or admin hotspot.
 * 5. Generic data-driven renderer: zero effect-specific branches (no 'if effect === glasses').
 * 6. Generic frame-aware coordinate projection: maps raw 1056x704 camera landmarks through
 *    the active theme frame's transparent cutout bbox (cover-fit) onto the composite canvas.
 * 7. Zero theme-name branching: transparent openings are derived dynamically from frame alpha.
 * 8. Strict fallback: seamlessly preserves baseline projection when no frame is active or loading.
 * 9. Multi-face tracking with generic EMA smoothing and graceful alpha fade-out on loss.
 * 10. Fully local: connects to extension daemon at http://localhost:8080/api/ar/stream.
 */
(function () {
  'use strict';

  const AR_SERVER_BASE = window.AR_SERVER_BASE || 'http://localhost:8080';
  const OVERLAY_CANVAS_ID = 'kiosk-ar-overlay';
  const DEFAULT_STREAM_ASPECT = 1056.0 / 704.0; // 1.5

  // Runtime State
  let overlayCanvas = null;
  let ctx = null;
  let eventSource = null;
  let animFrameId = null;
  let isStreamActive = false;
  let streamConfig = {
    aspectRatio: DEFAULT_STREAM_ASPECT,
    mirrored: false,
    enabled: true,
    activeEffect: 'glasses',
  };

  // Active frame overlay geometry tracking
  let activeFrameUrl = null;
  const frameGeometryCache = new Map(); // url -> { frameWidth, frameHeight, bbox, streamWidth, streamHeight, streamX, streamY }
  const pendingFrameLoads = new Set(); // url
  let lastFrameSyncTime = 0;
  const FRAME_SYNC_INTERVAL_MS = 2000;
  let isSyncingFrame = false;
  let frameLoadWarningLogged = false;

  // Data-driven effect cache
  let effectConfigs = {};
  const loadedAssets = new Map(); // assetPath -> HTMLImageElement

  // Multi-Face Tracker
  // trackId -> { id, center, interEyeDist, rollDeg, rollRad, anchors, unitVecEyes, unitVecUp, opacity, targetOpacity, lastSeen }
  const trackedFaces = new Map();
  let nextTrackId = 1;

  // Smoothing parameter (EMA alpha: 0.0 = static, 1.0 = raw / no smoothing)
  const SMOOTH_ALPHA = 0.40;
  const FADE_RATE = 0.15; // Opacity convergence rate per animation frame

  /**
   * Preload an image asset idempotently and cache it.
   */
  function getOrLoadAsset(assetRelPath) {
    if (!assetRelPath) return null;
    if (loadedAssets.has(assetRelPath)) {
      const img = loadedAssets.get(assetRelPath);
      return img.complete && img.naturalWidth > 0 ? img : null;
    }

    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.src = `${AR_SERVER_BASE}/${assetRelPath.replace(/^\/+/, '')}`;
    loadedAssets.set(assetRelPath, img);
    return null;
  }

  /**
   * Scan RGBA image buffer for the bounding box of pixels with alpha < 255.
   * Runs asynchronously outside the renderFrame loop.
   */
  function computeTransparentBBox(data, width, height, step) {
    let minX = width;
    let minY = height;
    let maxX = -1;
    let maxY = -1;

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        if (data[(y * width + x) * 4 + 3] < 255) {
          minY = y;
          y = height;
          break;
        }
      }
    }

    for (let y = height - 1; y >= 0; y--) {
      for (let x = 0; x < width; x++) {
        if (data[(y * width + x) * 4 + 3] < 255) {
          maxY = y;
          y = -1;
          break;
        }
      }
    }

    for (let x = 0; x < width; x++) {
      for (let y = minY; y <= maxY; y++) {
        if (data[(y * width + x) * 4 + 3] < 255) {
          minX = x;
          x = width;
          break;
        }
      }
    }

    for (let x = width - 1; x >= 0; x--) {
      for (let y = minY; y <= maxY; y++) {
        if (data[(y * width + x) * 4 + 3] < 255) {
          maxX = x;
          x = -1;
          break;
        }
      }
    }

    if (maxX < minX || maxY < minY) {
      return null;
    }

    return {
      x: minX * step,
      y: minY * step,
      width: (maxX - minX + 1) * step,
      height: (maxY - minY + 1) * step,
    };
  }

  /**
   * Load frame image once and derive camera placement inside transparent cutout.
   * Result is cached so scanning occurs only once per asset URL.
   */
  function loadAndCacheFrameGeometry(url) {
    if (!url || frameGeometryCache.has(url) || pendingFrameLoads.has(url)) {
      return;
    }
    pendingFrameLoads.add(url);

    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = function () {
      try {
        const fw = img.naturalWidth || img.width;
        const fh = img.naturalHeight || img.height;
        if (fw <= 0 || fh <= 0) {
          return;
        }

        const step = 2;
        const sw = Math.ceil(fw / step);
        const sh = Math.ceil(fh / step);
        const offCanvas = document.createElement('canvas');
        offCanvas.width = sw;
        offCanvas.height = sh;
        const offCtx = offCanvas.getContext('2d', { willReadFrequently: true });
        offCtx.drawImage(img, 0, 0, sw, sh);
        const imgData = offCtx.getImageData(0, 0, sw, sh);
        const bbox = computeTransparentBBox(imgData.data, sw, sh, step);

        if (bbox) {
          const cameraWidth = 1056;
          const cameraHeight = 704;
          const scale = Math.max(bbox.width / cameraWidth, bbox.height / cameraHeight);
          const streamWidth = cameraWidth * scale;
          const streamHeight = cameraHeight * scale;
          const streamX = bbox.x + (bbox.width - streamWidth) / 2.0;
          const streamY = bbox.y + (bbox.height - streamHeight) / 2.0;

          frameGeometryCache.set(url, {
            frameWidth: fw,
            frameHeight: fh,
            bbox: bbox,
            streamWidth: streamWidth,
            streamHeight: streamHeight,
            streamX: streamX,
            streamY: streamY,
          });
        } else {
          console.warn('[AR Overlay] No transparent opening detected in frame:', url);
        }
      } catch (err) {
        if (!frameLoadWarningLogged) {
          console.warn('[AR Overlay] Failed to parse frame transparency bbox:', err.message || err);
          frameLoadWarningLogged = true;
        }
      } finally {
        pendingFrameLoads.delete(url);
      }
    };
    img.onerror = function () {
      if (!frameLoadWarningLogged) {
        console.warn('[AR Overlay] Failed to load frame image for geometry:', url);
        frameLoadWarningLogged = true;
      }
      pendingFrameLoads.delete(url);
    };
    img.src = url;
  }

  /**
   * Query Photobooth-App configuration to detect active frame overlay.
   */
  async function syncActiveFrame(force) {
    const now = performance.now();
    if (!force && (isSyncingFrame || now - lastFrameSyncTime < FRAME_SYNC_INTERVAL_MS)) {
      return;
    }
    lastFrameSyncTime = now;
    isSyncingFrame = true;

    try {
      const res = await fetch('/api/config', { cache: 'no-store' });
      if (res.ok) {
        const cfg = await res.json();
        const uisettings = cfg.uisettings || {};
        if (uisettings.enable_livestream_frameoverlay && uisettings.livestream_frameoverlay_image) {
          const fullUrl = new URL(uisettings.livestream_frameoverlay_image, document.baseURI).href;
          if (activeFrameUrl !== fullUrl) {
            activeFrameUrl = fullUrl;
            loadAndCacheFrameGeometry(fullUrl);
          }
        } else {
          activeFrameUrl = null;
        }
      }
    } catch (err) {
      // Offline / error: continue with existing state or fallback
    } finally {
      isSyncingFrame = false;
    }
  }

  /**
   * Retrieve active frame geometry if loaded and cached, or null.
   */
  function getActiveFrameGeometry() {
    if (!activeFrameUrl) return null;
    return frameGeometryCache.get(activeFrameUrl) || null;
  }

  /**
   * Fetch AR configuration from the local extension server.
   */
  async function fetchARConfig() {
    try {
      const res = await fetch(`${AR_SERVER_BASE}/api/ar/config`, { cache: 'no-store' });
      if (res.ok) {
        const data = await res.json();
        streamConfig.enabled = !!data.enabled;
        streamConfig.activeEffect = data.active_effect || 'glasses';
        effectConfigs = data.effects || {};

        // Preload assets for all configured effects
        for (const eff of Object.values(effectConfigs)) {
          if (Array.isArray(eff.elements)) {
            for (const el of eff.elements) {
              if (el.asset) getOrLoadAsset(el.asset);
            }
          }
        }
      }
    } catch (err) {
      // Extension server may still be initializing; will retry on connect
    }
  }

  /**
   * Determine displayed preview geometry by inspecting the actual #canvas-stream
   * element bounds and accounting for aspect ratio / object-fit: contain.
   */
  function computeStreamGeometry() {
    const streamElem = document.getElementById('canvas-stream');
    if (!streamElem || streamElem.offsetParent === null) {
      return null;
    }

    const rect = streamElem.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      return null;
    }

    // Determine stream canvas aspect ratio
    let camAspect = streamConfig.aspectRatio || DEFAULT_STREAM_ASPECT;
    if (streamElem.width > 0 && streamElem.height > 0) {
      camAspect = streamElem.width / streamElem.height;
    }

    const elemAspect = rect.width / rect.height;
    let renderW, renderH, renderLeft, renderTop;

    if (elemAspect > camAspect) {
      // Pillarboxed (element wider than stream; bars on sides)
      renderH = rect.height;
      renderW = rect.height * camAspect;
      renderLeft = rect.left + (rect.width - renderW) / 2.0;
      renderTop = rect.top;
    } else {
      // Letterboxed (element taller than stream; bars top/bottom)
      renderW = rect.width;
      renderH = rect.width / camAspect;
      renderLeft = rect.left;
      renderTop = rect.top + (rect.height - renderH) / 2.0;
    }

    return {
      left: Math.round(renderLeft),
      top: Math.round(renderTop),
      width: Math.max(1, Math.round(renderW)),
      height: Math.max(1, Math.round(renderH)),
      mirrored: streamConfig.mirrored,
    };
  }

  /**
   * Map normalized [0, 1] camera point to canvas-local coordinates.
   * When a frame overlay is active, projects camera coordinates through
   * the transparent opening cover-fit geometry onto the composite canvas.
   * Falls back to standard full-stream projection when no frame is enabled.
   */
  function mapNormalizedPoint(normPt, geo, geom) {
    const nx = normPt[0];
    const ny = normPt[1];
    const nxMapped = geo.mirrored ? (1.0 - nx) : nx;

    if (geom) {
      const frameX = geom.streamX + nxMapped * geom.streamWidth;
      const frameY = geom.streamY + ny * geom.streamHeight;
      const canvasX = (frameX / geom.frameWidth) * geo.width;
      const canvasY = (frameY / geom.frameHeight) * geo.height;
      return [canvasX, canvasY];
    }

    // Baseline fallback (no active frame or geometry pending)
    const canvasX = nxMapped * geo.width;
    const canvasY = ny * geo.height;
    return [canvasX, canvasY];
  }

  /**
   * Exponential Moving Average (EMA) helper.
   */
  function ema(current, target, alpha) {
    return alpha * target + (1.0 - alpha) * current;
  }

  /**
   * Update tracked faces state with newly received raw detection packet.
   * Matches detections to existing tracks by nearest centroid distance.
   */
  function updateTracks(rawFaces, now) {
    const matchedTrackIds = new Set();

    for (const raw of rawFaces) {
      const rx = raw.center_eyes[0];
      const ry = raw.center_eyes[1];

      // Find best matching existing track within distance threshold
      let bestDist = 0.18; // Max normalized distance threshold (~18% of frame)
      let bestTrack = null;

      for (const [tId, track] of trackedFaces.entries()) {
        if (matchedTrackIds.has(tId)) continue;
        const dx = track.rawCenter[0] - rx;
        const dy = track.rawCenter[1] - ry;
        const d = Math.hypot(dx, dy);
        if (d < bestDist) {
          bestDist = d;
          bestTrack = track;
        }
      }

      if (bestTrack) {
        // Update existing track with temporal smoothing
        matchedTrackIds.add(bestTrack.id);
        bestTrack.rawCenter = [rx, ry];
        bestTrack.center = [
          ema(bestTrack.center[0], rx, SMOOTH_ALPHA),
          ema(bestTrack.center[1], ry, SMOOTH_ALPHA),
        ];
        bestTrack.interEyeDist = ema(bestTrack.interEyeDist, raw.inter_eye_distance, SMOOTH_ALPHA);
        if (typeof raw.mouth_width === 'number' && raw.mouth_width > 0) {
          bestTrack.mouthWidth = typeof bestTrack.mouthWidth === 'number'
            ? ema(bestTrack.mouthWidth, raw.mouth_width, SMOOTH_ALPHA)
            : raw.mouth_width;
        }
        if (raw.expression && typeof raw.expression.mouth_ratio === 'number') {
          bestTrack.smoothMouthRatio = typeof bestTrack.smoothMouthRatio === 'number'
            ? ema(bestTrack.smoothMouthRatio, raw.expression.mouth_ratio, SMOOTH_ALPHA)
            : raw.expression.mouth_ratio;
        }

        // Smooth roll angle
        let dRoll = raw.roll_angle_deg - bestTrack.rollDeg;
        while (dRoll > 180) dRoll -= 360;
        while (dRoll < -180) dRoll += 360;
        bestTrack.rollDeg += dRoll * SMOOTH_ALPHA;
        bestTrack.rollRad = (bestTrack.rollDeg * Math.PI) / 180.0;

        // Smooth anchors
        if (raw.anchors) {
          for (const [aKey, aPt] of Object.entries(raw.anchors)) {
            if (!bestTrack.anchors[aKey]) {
              bestTrack.anchors[aKey] = [aPt[0], aPt[1]];
            } else {
              bestTrack.anchors[aKey] = [
                ema(bestTrack.anchors[aKey][0], aPt[0], SMOOTH_ALPHA),
                ema(bestTrack.anchors[aKey][1], aPt[1], SMOOTH_ALPHA),
              ];
            }
          }
        }

        bestTrack.unitVecEyes = raw.unit_vec_eyes;
        bestTrack.unitVecUp = raw.unit_vec_up;
        bestTrack.targetOpacity = 1.0;
        bestTrack.lastSeen = now;
        bestTrack.expression = raw.expression || null;
        bestTrack.expressionEvents = Array.isArray(raw.expression_events) ? raw.expression_events : [];
      } else {
        // Create new track
        const tId = nextTrackId++;
        matchedTrackIds.add(tId);
        const anchorsCopy = {};
        if (raw.anchors) {
          for (const [k, v] of Object.entries(raw.anchors)) {
            anchorsCopy[k] = [v[0], v[1]];
          }
        }

        trackedFaces.set(tId, {
          id: tId,
          rawCenter: [rx, ry],
          center: [rx, ry],
          interEyeDist: raw.inter_eye_distance,
          mouthWidth: (typeof raw.mouth_width === 'number' && raw.mouth_width > 0) ? raw.mouth_width : null,
          smoothMouthRatio: (raw.expression && typeof raw.expression.mouth_ratio === 'number')
            ? raw.expression.mouth_ratio
            : null,
          rollDeg: raw.roll_angle_deg,
          rollRad: raw.roll_angle_rad,
          anchors: anchorsCopy,
          unitVecEyes: raw.unit_vec_eyes,
          unitVecUp: raw.unit_vec_up,
          opacity: 0.0, // Fade in gently
          targetOpacity: 1.0,
          lastSeen: now,
          expression: raw.expression || null,
          expressionEvents: Array.isArray(raw.expression_events) ? raw.expression_events : [],
        });
      }
    }

    // Set target opacity to 0 for unobserved tracks (initiates graceful fade-out)
    for (const [tId, track] of trackedFaces.entries()) {
      if (!matchedTrackIds.has(tId)) {
        track.targetOpacity = 0.0;
      }
    }
  }

  /**
   * Synchronize the overlay canvas position, size, and backing buffer resolution
   * with the computed live stream bounds.
   */
  function syncCanvasBounds(geo) {
    if (!overlayCanvas || !geo) return;

    const leftPx = `${geo.left}px`;
    const topPx = `${geo.top}px`;
    const widthPx = `${geo.width}px`;
    const heightPx = `${geo.height}px`;

    overlayCanvas.style.setProperty('left', leftPx, 'important');
    overlayCanvas.style.setProperty('top', topPx, 'important');
    overlayCanvas.style.setProperty('width', widthPx, 'important');
    overlayCanvas.style.setProperty('height', heightPx, 'important');

    const dpr = window.devicePixelRatio || 1;
    const bufW = Math.round(geo.width * dpr);
    const bufH = Math.round(geo.height * dpr);

    if (overlayCanvas.width !== bufW || overlayCanvas.height !== bufH) {
      overlayCanvas.width = bufW;
      overlayCanvas.height = bufH;
    }
  }

  /**
   * Evaluates whether an element's declarative visibility rule is satisfied.
   * Completely generic: zero effect-specific branches, zero detector assumptions.
   *
   * Semantics:
   * - No visible_when rule: return true (static element, unconditionally visible).
   * - visible_when present but malformed (not an object): return false (fail-closed).
   * - visible_when.expression defined:
   *     - track.expression missing or null: return false (fail-closed).
   *     - equals defined: compare actual expression value against equals.
   *     - equals omitted: evaluate truthiness of actual expression value.
   * - Malformed rule or unhandled error: fail safely and return false (fail-closed).
   */
  function isElementVisible(element, track) {
    if (!element || !element.visible_when) {
      return true;
    }

    try {
      const rule = element.visible_when;
      if (typeof rule !== 'object' || rule === null) {
        return false;
      }

      if (typeof rule.expression === 'string') {
        if (!track || !track.expression || typeof track.expression !== 'object') {
          return false;
        }

        const actualVal = track.expression[rule.expression];
        if (rule.equals !== undefined) {
          return actualVal === rule.equals;
        }

        return Boolean(actualVal);
      }

      return false;
    } catch (err) {
      return false;
    }
  }

  /**
   * Main render loop executed on requestAnimationFrame.
   * Completely data-driven with zero effect-specific branches.
   * Visible AR canvas matches and is strictly clipped to the live camera preview bounds.
   */
  function renderFrame() {
    if (!overlayCanvas || !ctx) {
      animFrameId = requestAnimationFrame(renderFrame);
      return;
    }

    const geo = computeStreamGeometry();
    if (!geo) {
      if (overlayCanvas.style.display !== 'none') {
        overlayCanvas.style.display = 'none';
      }
      animFrameId = requestAnimationFrame(renderFrame);
      return;
    }

    if (overlayCanvas.style.display !== 'block') {
      overlayCanvas.style.display = 'block';
    }

    syncCanvasBounds(geo);

    const dpr = window.devicePixelRatio || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    // Clear visible stream area
    ctx.clearRect(0, 0, geo.width, geo.height);

    if (!streamConfig.enabled) {
      animFrameId = requestAnimationFrame(renderFrame);
      return;
    }

    // Throttled frame config check
    syncActiveFrame();

    const activeGeom = getActiveFrameGeometry();
    const now = performance.now();
    const activeConfig = effectConfigs[streamConfig.activeEffect];

    // Explicit 2D clipping boundary strictly matching camera preview rectangle
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, geo.width, geo.height);
    ctx.clip();

    // Process and render tracked faces
    for (const [tId, track] of trackedFaces.entries()) {
      // Smooth opacity transition
      track.opacity += (track.targetOpacity - track.opacity) * FADE_RATE;

      // Clean up stale or fully invisible tracks
      if (track.targetOpacity === 0.0 && (track.opacity < 0.02 || now - track.lastSeen > 350)) {
        trackedFaces.delete(tId);
        continue;
      }

      if (track.opacity <= 0.01 || !activeConfig || !Array.isArray(activeConfig.elements)) {
        continue;
      }

      // Render each configured element in the active effect
      for (const el of activeConfig.elements) {
        if (!isElementVisible(el, track)) {
          continue;
        }

        const img = getOrLoadAsset(el.asset);
        if (!img) continue; // Asset still loading

        // 1. Resolve anchor point in canvas-local coordinates
        const anchorName = el.anchor || 'eyes_center';
        const rawAnchorPt = track.anchors[anchorName] || track.center;
        const [anchorScreenX, anchorScreenY] = mapNormalizedPoint(rawAnchorPt, geo, activeGeom);

        // 2. Compute element screen scale proportional to tracked face reference distance
        const cameraScreenWidth = activeGeom
          ? (activeGeom.streamWidth / activeGeom.frameWidth) * geo.width
          : geo.width;
        let scaleRefDist = track.interEyeDist * cameraScreenWidth;
        if (el.scale_reference === 'mouth_width' && typeof track.mouthWidth === 'number' && track.mouthWidth > 0) {
          scaleRefDist = track.mouthWidth * cameraScreenWidth;
        }
        const scaleFactor = typeof el.scale_factor === 'number'
          ? el.scale_factor
          : (typeof el.width_scale === 'number' ? el.width_scale : 1.0);
        const targetW = Math.max(10, scaleRefDist * scaleFactor);
        const aspect = img.naturalHeight / Math.max(1, img.naturalWidth);

        // Compute reactive vertical scale / extension if configured
        let heightMultiplier = 1.0;
        if (el.reactive_height && typeof el.reactive_height === 'object') {
          const rh = el.reactive_height;
          const exprKey = rh.expression || rh.expression_source || 'mouth_ratio';
          let mar = null;
          if (exprKey === 'mouth_ratio') {
            mar = (typeof track.smoothMouthRatio === 'number')
              ? track.smoothMouthRatio
              : (track.expression && typeof track.expression.mouth_ratio === 'number' ? track.expression.mouth_ratio : null);
          } else if (track.expression && typeof track.expression[exprKey] === 'number') {
            mar = track.expression[exprKey];
          }

          if (typeof mar === 'number') {
            const inMin = typeof rh.input_min === 'number' ? rh.input_min : 0.20;
            const inMax = typeof rh.input_max === 'number' ? rh.input_max : 0.50;
            const outMin = typeof rh.min_scale === 'number' ? rh.min_scale : (typeof rh.min_height === 'number' ? rh.min_height : 0.40);
            const outMax = typeof rh.max_scale === 'number' ? rh.max_scale : (typeof rh.max_height === 'number' ? rh.max_height : 1.25);

            const denom = inMax - inMin;
            const norm = denom > 1e-4 ? Math.max(0.0, Math.min(1.0, (mar - inMin) / denom)) : 0.0;
            heightMultiplier = outMin + norm * (outMax - outMin);
          }
        }
        const targetH = Math.max(5, targetW * aspect * heightMultiplier);

        // 3. Compute rotation and coordinate orientation
        let roll = track.rollRad;
        if (geo.mirrored) {
          roll = -roll;
        }

        // Unit vectors in screen space
        const cosR = Math.cos(roll);
        const sinR = Math.sin(roll);
        const uEyesX = cosR;
        const uEyesY = sinR;
        const uUpX = sinR;
        const uUpY = -cosR;

        // 4. Resolve normalized asset anatomical anchor (defaults to geometric center [0.5, 0.5])
        const assetAnchorX = typeof el.asset_anchor_x === 'number' ? el.asset_anchor_x : 0.5;
        const assetAnchorY = typeof el.asset_anchor_y === 'number' ? el.asset_anchor_y : 0.5;

        // 5. Apply configured fine-tune offsets along head axes
        const offEyes = (el.offset_along_eyes || 0.0) * targetW;
        const offUp = (el.offset_along_up || 0.0) * targetH;

        // Target attachment point on the face in screen coordinates
        const targetFaceX = anchorScreenX + uEyesX * offEyes + uUpX * offUp;
        const targetFaceY = anchorScreenY + uEyesY * offEyes + uUpY * offUp;

        // 6. Draw element rotated directly around its anatomical anchor
        ctx.save();
        ctx.globalAlpha = Math.max(0.0, Math.min(1.0, track.opacity));
        ctx.translate(targetFaceX, targetFaceY);
        ctx.rotate(roll);
        ctx.drawImage(img, -assetAnchorX * targetW, -assetAnchorY * targetH, targetW, targetH);
        ctx.restore();
      }
    }

    ctx.restore(); // Restore clip boundary
    animFrameId = requestAnimationFrame(renderFrame);
  }

  /**
   * Connect to Server-Sent Events (SSE) stream on local extension server.
   */
  function startSSE() {
    if (eventSource) return;

    const streamUrl = `${AR_SERVER_BASE}/api/ar/stream`;
    eventSource = new EventSource(streamUrl);

    eventSource.onmessage = function (event) {
      if (!event.data) return;
      try {
        const data = JSON.parse(event.data);
        if (typeof data.enabled === 'boolean') {
          streamConfig.enabled = data.enabled;
        }
        if (data.active_effect) {
          streamConfig.activeEffect = data.active_effect;
        }
        if (data.stream_w && data.stream_h) {
          streamConfig.aspectRatio = data.stream_w / data.stream_h;
        }
        if (Array.isArray(data.faces)) {
          updateTracks(data.faces, performance.now());
        }
      } catch (err) {
        // Skip malformed packet
      }
    };

    eventSource.onerror = function () {
      // Reconnection handled automatically by browser EventSource
    };
  }

  /**
   * Disconnect SSE stream and release network resources.
   */
  function stopSSE() {
    if (eventSource) {
      eventSource.close();
      eventSource = null;
    }
    trackedFaces.clear();
    if (ctx && overlayCanvas) {
      ctx.clearRect(0, 0, overlayCanvas.width, overlayCanvas.height);
      overlayCanvas.style.display = 'none';
    }
  }

  /**
   * Ensure overlay canvas is mounted on the DOM directly above the live stream.
   * Anchored strictly to the live preview element bounds.
   */
  function ensureOverlayCanvas() {
    let canvas = document.getElementById(OVERLAY_CANVAS_ID);
    if (!canvas) {
      canvas = document.createElement('canvas');
      canvas.id = OVERLAY_CANVAS_ID;
      canvas.style.cssText = [
        'position: fixed !important',
        'overflow: hidden !important',
        'clip-path: inset(0px round 0px) !important',
        '-webkit-clip-path: inset(0px round 0px) !important',
        'z-index: 2 !important', // Sits at camera stream level, strictly below UI controls (buttons, headers, modals)
        'pointer-events: none !important',
        '-webkit-user-select: none !important',
        'user-select: none !important',
        'display: none',
      ].join(';');

      // Mount directly onto body
      (document.body || document.documentElement).appendChild(canvas);
    }

    overlayCanvas = canvas;
    ctx = overlayCanvas.getContext('2d');
  }

  /**
   * Detect presence of live stream in Photobooth-App and manage stream lifecycle.
   */
  function checkStreamPresence() {
    const streamElem = document.getElementById('canvas-stream');
    const isPresent = !!streamElem && streamElem.offsetParent !== null;

    if (isPresent && !isStreamActive) {
      isStreamActive = true;
      ensureOverlayCanvas();
      syncActiveFrame(true);
      const geo = computeStreamGeometry();
      if (geo) {
        syncCanvasBounds(geo);
        overlayCanvas.style.display = 'block';
      }
      startSSE();
      if (!animFrameId) {
        animFrameId = requestAnimationFrame(renderFrame);
      }
    } else if (!isPresent && isStreamActive) {
      isStreamActive = false;
      stopSSE();
      if (animFrameId) {
        cancelAnimationFrame(animFrameId);
        animFrameId = null;
      }
    }
  }

  /**
   * Initialize AR Overlay Runtime.
   */
  async function init() {
    await fetchARConfig();
    await syncActiveFrame(true);
    ensureOverlayCanvas();
    checkStreamPresence();

    // Re-check frame on user interaction (e.g. theme button clicked)
    window.addEventListener('click', () => {
      syncActiveFrame(true);
    }, { passive: true });

    // Observe DOM mutations to detect when Photobooth mounts or unmounts the stream
    const observer = new MutationObserver(() => {
      checkStreamPresence();
    });
    observer.observe(document.body, { childList: true, subtree: true });

    // Handle window resize and layout changes
    window.addEventListener('resize', () => {
      const geo = computeStreamGeometry();
      if (geo) {
        syncCanvasBounds(geo);
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
