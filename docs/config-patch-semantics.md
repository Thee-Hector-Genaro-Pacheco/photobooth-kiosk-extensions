# Photobooth-App Config PATCH Semantics & Contract

This document analyzes the exact behavior and semantics of `PATCH /api/admin/config/{configurable}`, verified directly against the live OpenAPI document (`http://192.168.2.3:8000/api/openapi.json`) and the installed Photobooth-App Python backend source code on the Raspberry Pi.

---

## 1. Exact Endpoint Details

- **Path:** `/api/admin/config/{configurable}`
  - For main application configuration: `PATCH /api/admin/config/app`
- **HTTP Method:** `PATCH`
- **Authentication:** Requires `OAuth2PasswordBearer` (`Authorization: Bearer <access_token>`)
- **Query Parameter:**
  - `reload` (boolean, default: `false`): If `true`, invokes `container.reload()` to restart all background services.
- **Request Content-Type:** `application/json`
- **Request Body Schema:** Generic JSON object (`dict[str, Any]`) validated by backend Pydantic models.
- **Response:**
  - `200 OK`: Configuration updated and persisted.
  - `422 Unprocessable Entity`: Pydantic validation failure.

---

## 2. Partial vs. Full Configuration Behavior

### Finding: The endpoint does NOT safely perform deep partial merges.

Inside the Photobooth-App source (`photobooth/services/configuration.py`):
```python
def validate_and_set_current_and_persist(self, configurable: str, updated_config: dict[AnyStr, Any]):
    appconfig_or_plugin_config = self._get_appconfig_or_pluginconfig(configurable)
    updated_config_validated = appconfig_or_plugin_config.model_validate(updated_config)
    updated_config_validated.persist()
    appconfig_or_plugin_config.__init__()
```

When `model_validate(updated_config)` executes:
1. While top-level groups omitted entirely can fallback to disk via Pydantic Settings `JsonConfigSettingsSource`, **nested sub-models and lists are NOT merged element-wise**.
2. If an incomplete dictionary is passed for a list item (e.g. `actions.image`), Pydantic does not merge the dictionary into the existing item. It attempts to construct a brand-new `SingleImageConfigurationSet`.
3. Because required fields (`jobcontrol`, `trigger`) are missing in a partial payload, validation immediately aborts with:
   ```text
   ValidationError:
   actions.image.0.jobcontrol: Field required
   actions.image.0.trigger: Field required
   ```
4. Sending a sparse partial patch fails with HTTP 422.

---

## 3. Handling of Lists (`actions.image`, `actions.collage`)

- **Lists are REPLACED, not merged.**
- Passing `{"actions": {"image": [...]}}` replaces the entire `image` list.
- Each element within `actions.image` or `actions.collage` must be a fully specified, valid configuration set object containing:
  - `name`
  - `jobcontrol`
  - `processing`
  - `trigger`
- If you supply a list containing only `processing`, all other required parameters are missing and rejected.

---

## 4. Nested Dictionaries

- Standalone top-level group dictionaries (such as `uisettings`) merge with existing disk configuration if other top-level keys are omitted.
- However, nested dictionaries inside list structures (such as `actions.image[0].processing`) do **NOT** merge with the active list item.

---

## 5. Persistence Behavior

- **Configuration is automatically persisted to disk.**
- On validation success, `persist()`:
  1. Creates a timestamped backup of the current configuration file in `./config/` (`config.json_backup-YYYYMMDD-HHMMSS`), retaining the 10 most recent backups.
  2. Overwrites `./config/config.json` with the newly validated model.
  3. Reloads the active in-memory singleton (`appconfig.__init__()`).

---

## 6. Reload Parameter (`reload=true` vs `reload=false`)

- **`reload=false`:**
  - Persists `config.json` and updates the in-memory singleton `appconfig`.
  - `ProcessingService.trigger_action` evaluates `appconfig.actions` dynamically on each capture. Captured single photos and collages immediately use the updated theme overlay assets without restarting services.
  - Recommended for fast, seamless theme switching without interrupting the live kiosk session.
- **`reload=true`:**
  - In addition to persisting and in-memory reload, calls `container.reload()`.
  - Fully restarts all hardware services: `AcquisitionService` (camera driver), `GpioService` (hardware buttons), etc.
  - Causes camera viewfinder downtime and takes several seconds.
  - Only required when changing hardware drivers, GPIO pins, or backend parameters.

---

## 7. Official Photobooth-App Admin Implementation

Inspection of the compiled Photobooth-App Admin web client (`AdminConfigPage`) confirms this architecture:
1. Performs `GET /api/admin/config/app` to fetch the complete current configuration object.
2. Modifies only the selected fields in the local state.
3. Submits the **full modified configuration object** via `PATCH /api/admin/config/app`.

---

## 8. Safest Write Strategy for Theme Selector

To reliably switch themes without validation errors or resetting kiosk hardware configurations, the theme applicator must implement a **Read-Modify-Write (Full Payload)** strategy:

1. **Authenticate:** Call `POST /api/admin/auth/token` using admin credentials to obtain a Bearer token.
2. **Read Current State:** Call `GET /api/config` (or `GET /api/admin/config/app`) to retrieve the active, complete configuration dictionary.
3. **Patch Target Fields:** Deep-update only the verified theme keys:
   - `config["actions"]["image"][0]["processing"]["img_frame_enable"] = <bool>`
   - `config["actions"]["image"][0]["processing"]["img_frame_file"] = <path | null>`
   - `config["actions"]["collage"][0]["processing"]["canvas_img_front_file"] = <path | null>`
   - `config["uisettings"]["enable_livestream_frameoverlay"] = <bool>`
   - `config["uisettings"]["livestream_frameoverlay_image"] = <path | null>`
4. **Submit Full Config:** Send the full modified dictionary to `PATCH /api/admin/config/app?reload=false` with `Authorization: Bearer <access_token>`.
5. **Outcome:** Guarantees schema compliance, preserves all existing hardware and camera settings, automatically creates a backup on the Pi, and immediately activates the new theme.
