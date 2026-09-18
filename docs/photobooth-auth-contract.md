# Photobooth-App Admin Authentication Contract

This document specifies the authentication contract for Photobooth-App admin endpoints, verified directly against the live OpenAPI specification (`/api/openapi.json`).

> [!IMPORTANT]
> All admin operations requiring authorization depend on OAuth2 password bearer tokens issued by this workflow. Credentials must never be hardcoded, tracked in source control, or logged.

---

## 1. Security Scheme

- **Scheme Name:** `OAuth2PasswordBearer`
- **Type:** `oauth2`
- **Flow:** `password`
- **Token URL:** `/api/admin/auth/token`
- **Scopes:** None defined (`{}`)

---

## 2. Token Endpoint (`POST /api/admin/auth/token`)

- **Path:** `/api/admin/auth/token`
- **HTTP Method:** `POST`
- **Request Content-Type:** `application/x-www-form-urlencoded`

### Request Body Schema (`Body_login_for_access_token_api_admin_auth_token_post`)

Form-encoded parameters:

| Field Name | Type | Required | Description / Rules |
| :--- | :--- | :--- | :--- |
| `username` | string | **Yes** | Admin account username |
| `password` | string (password) | **Yes** | Admin account password |
| `grant_type` | string \| null | No | Optional, pattern: `^password$` |
| `scope` | string | No | Default: `""` |
| `client_id` | string \| null | No | Optional OAuth2 client ID |
| `client_secret` | string \| null | No | Optional OAuth2 client secret |

### Success Response (`200 OK`)

- **Content-Type:** `application/json`
- **Schema:** `Token`

| Field Name | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `access_token` | string | **Yes** | Bearer token string used for authorized requests |
| `token_type` | string | **Yes** | Token type, typically `"bearer"` |

### Error Responses
- `422 Unprocessable Entity`: Request validation failed (e.g., missing required form fields or invalid content-type).

---

## 3. Bearer Token Usage

To authenticate requests to protected endpoints (such as `PATCH /api/admin/config/{configurable}` or `GET /api/admin/auth/me`), include the retrieved `access_token` in the HTTP `Authorization` header:

```http
Authorization: Bearer <access_token>
```

---

## 4. User Identity Endpoint (`GET /api/admin/auth/me`)

- **Path:** `/api/admin/auth/me`
- **HTTP Method:** `GET`
- **Security Scheme:** `OAuth2PasswordBearer` (requires `Authorization: Bearer <access_token>`)

### Success Response (`200 OK`)

- **Content-Type:** `application/json`
- **Schema:** `User`

| Field Name | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `username` | string | **Yes** | Verified username associated with the bearer token |
| `full_name` | string \| null | No | Full name of the user, if configured |

### Behavior
- Used to verify that an access token is valid and active before issuing administrative configuration patches.
- Returns HTTP 200 with the `User` object if the token is valid; unauthorized requests are rejected prior to execution.
