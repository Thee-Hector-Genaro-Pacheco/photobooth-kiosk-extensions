/**
 * ui/kiosk-ar-overlay.js - Photobooth-App Live AR Face Overlay Runtime.
 *
 * Architectural Guarantees:
 * 1. Overlay is a separate transparent canvas layer above existing live preview.
 * 2. Does NOT read from or modify Photobooth-App's OffscreenCanvas or worker.
 * 3. Does NOT replace Photobooth-App's camera stream.
 * 4. pointer-events: none ensures zero interference with buttons, themes, or admin hotspot.
 * 5. Generic data-driven renderer: zero effect-specific branches (no 'if effect === glasses').
 * 6. Viewport mapping handles object-fit: contain, aspect ratio, letterbox/pillarbox, and mirroring.
 * 7. Multi-face tracking with generic EMA smoothing and graceful alpha fade-out on loss.
 * 8. Fully local: connects to extension daemon at http://localhost:8080/api/ar/stream.
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

    // Determine camera stream aspect ratio
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
   * Canvas is anchored and sized to the visible stream, so (0, 0) is top-left
   * and (geo.width, geo.height) is bottom-right of the camera image.
   */
  function mapNormalizedPoint(normPt, geo) {
    let nx = normPt[0];
    const ny = normPt[1];

    if (geo.mirrored) {
      nx = 1.0 - nx;
    }

    const canvasX = nx * geo.width;
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
          rollDeg: raw.roll_angle_deg,
          rollRad: raw.roll_angle_rad,
          anchors: anchorsCopy,
          unitVecEyes: raw.unit_vec_eyes,
          unitVecUp: raw.unit_vec_up,
          opacity: 0.0, // Fade in gently
          targetOpacity: 1.0,
          lastSeen: now,
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
        const img = getOrLoadAsset(el.asset);
        if (!img) continue; // Asset still loading

        // 1. Resolve anchor point in canvas-local coordinates
        const anchorName = el.anchor || 'eyes_center';
        const rawAnchorPt = track.anchors[anchorName] || track.center;
        const [anchorScreenX, anchorScreenY] = mapNormalizedPoint(rawAnchorPt, geo);

        // 2. Compute element screen scale proportional to tracked face inter-eye distance
        const scaleRefDist = track.interEyeDist * geo.width;
        const scaleFactor = typeof el.scale_factor === 'number' ? el.scale_factor : 1.0;
        const targetW = Math.max(10, scaleRefDist * scaleFactor);
        const aspect = img.naturalHeight / Math.max(1, img.naturalWidth);
        const targetH = Math.max(5, targetW * aspect);

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
    ensureOverlayCanvas();
    checkStreamPresence();

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
