package accounts

import (
	"net/http"
	"strconv"
	"strings"

	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/logx"
)

// Router es donde se montan las rutas: *app.App.
type Router interface {
	HandlePublic(pattern string, h http.Handler)
}

// API son las rutas de cuentas y sesiones de la API pública (§4.2, §4.3) y las páginas de los
// enlaces de los correos.
type API struct {
	s *Service
}

// NewAPI prepara las rutas del servicio.
func NewAPI(s *Service) *API { return &API{s: s} }

// Mount monta las rutas. Las de /v1 exigen X-Eldmark-Protocol (426); las páginas de los enlaces
// no.
func (a *API) Mount(r Router) {
	v1 := func(pattern string, h http.HandlerFunc) {
		r.HandlePublic(pattern, httpx.RequireProtocol(a.s.minProtocol, h))
	}
	game := func(pattern string, h http.HandlerFunc) {
		r.HandlePublic(pattern, httpx.RequireProtocol(a.s.minProtocol, a.RequireSession(false, h)))
	}
	privacy := func(pattern string, h http.HandlerFunc) {
		r.HandlePublic(pattern, httpx.RequireProtocol(a.s.minProtocol, a.RequireSession(true, h)))
	}

	v1("GET /v1/status", a.status)
	v1("GET /v1/legal", a.legalIndex)
	v1("GET /v1/legal/{kind}", a.legalText)
	v1("POST /v1/accounts", a.register)
	v1("POST /v1/sessions", a.login)
	v1("POST /v1/sessions/refresh", a.refresh)
	v1("POST /v1/account/verify-email", a.verifyEmail)
	v1("POST /v1/account/password-reset", a.passwordReset)
	v1("POST /v1/account/password-reset/confirm", a.passwordResetConfirm)
	v1("POST /v1/account/email/confirm", a.emailConfirm)
	v1("POST /v1/account/email/revert", a.emailRevert)

	// La sesión de privacidad de una cuenta sancionada solo admite estas (§4.2).
	privacy("DELETE /v1/sessions/current", a.logout)
	privacy("GET /v1/account", a.account)
	privacy("POST /v1/account/deletion", a.requestDeletion)
	privacy("DELETE /v1/account/deletion", a.cancelDeletion)
	privacy("POST /v1/account/export", a.export)

	game("POST /v1/account/accept", a.accept)
	game("PUT /v1/account/consents", a.consents)
	game("POST /v1/account/verify-email/resend", a.resendVerification)
	game("POST /v1/account/password", a.changePassword)
	game("POST /v1/account/email", a.changeEmail)

	a.mountPages(r)
}

// RequireSession exige un token de acceso vivo (si no, 401 unauthorized) y deja la sesión en el
// contexto ([SessionFrom]). Con allowPrivacy false, la ruta no admite la sesión de privacidad ni
// una cuenta con una suspensión o expulsión vigente: 403 account_suspended o account_banned con
// until y reason (§4.2). Si la sanción de una sesión de privacidad ya terminó, 401: al volver a
// iniciar sesión recibe una de juego. Los paquetes siguientes (personajes, enter) montan sus rutas
// con RequireSession(false, …).
func (a *API) RequireSession(allowPrivacy bool, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearer(r)
		if !ok {
			httpx.WriteError(w, errUnauthorized())
			return
		}
		ctx := r.Context()
		sess, err := a.s.Authenticate(ctx, token)
		if err != nil {
			httpx.Fail(w, r, a.s.log, err)
			return
		}
		if sess == nil {
			httpx.WriteError(w, errUnauthorized())
			return
		}
		logx.SetAccount(ctx, sess.AccountID)
		if !allowPrivacy {
			restriction, err := ActiveRestriction(ctx, a.s.pool, sess.AccountID, a.s.clock.Now())
			if err != nil {
				httpx.Fail(w, r, a.s.log, err)
				return
			}
			switch {
			case restriction != nil:
				httpx.WriteError(w, restriction.Error())
				return
			case sess.Scope == ScopePrivacy:
				httpx.WriteError(w, errUnauthorized())
				return
			}
		}
		h.ServeHTTP(w, r.WithContext(WithSession(ctx, sess)))
	})
}

func bearer(r *http.Request) (string, bool) {
	v := r.Header.Get("Authorization")
	scheme, token, found := strings.Cut(v, " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

func (a *API) meta(r *http.Request) ClientMeta {
	return ClientMeta{IP: httpx.ClientIP(r, a.s.cfg.TrustedProxies), UserAgent: r.UserAgent(),
		Protocol: httpx.ClientProtocol(r)}
}

// decode lee el cuerpo JSON (16 KB, estricto); si falla, escribe el error y devuelve false.
func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if e := httpx.DecodeJSON(w, r, httpx.PublicBodyLimit, v); e != nil {
		httpx.WriteError(w, e)
		return false
	}
	return true
}

func (a *API) fail(w http.ResponseWriter, r *http.Request, err error) { httpx.Fail(w, r, a.s.log, err) }

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func (a *API) status(w http.ResponseWriter, r *http.Request) {
	v, err := a.s.Status(r.Context())
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}

func (a *API) legalIndex(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, a.s.LegalIndex())
}

func (a *API) legalText(w http.ResponseWriter, r *http.Request) {
	d := a.s.LegalText(r.PathValue("kind"))
	if d == nil {
		httpx.WriteError(w, httpx.ErrNotFound)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/markdown; charset=utf-8")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Eldmark-Legal-Version", strconv.Itoa(d.Version))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(d.Text)
}

func (a *API) register(w http.ResponseWriter, r *http.Request) {
	var req RegisterRequest
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.Register(r.Context(), req, a.meta(r)); err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, struct{}{})
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    *string `json:"email"`
		Password *string `json:"password"`
	}
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s.Login(r.Context(), str(req.Email), str(req.Password), a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	logx.SetAccount(r.Context(), int64(res.Account.AccountID))
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken *string `json:"refresh_token"`
	}
	if !decode(w, r, &req) {
		return
	}
	res, err := a.s.Refresh(r.Context(), str(req.RefreshToken), a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	if err := a.s.Logout(r.Context(), SessionFrom(r.Context())); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) account(w http.ResponseWriter, r *http.Request) {
	v, err := a.s.Account(r.Context(), SessionFrom(r.Context()))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, v)
}

func (a *API) accept(w http.ResponseWriter, r *http.Request) {
	var req LegalVersions
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.Accept(r.Context(), SessionFrom(r.Context()), req); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) consents(w http.ResponseWriter, r *http.Request) {
	var req Consents
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.PutConsents(r.Context(), SessionFrom(r.Context()), req); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type tokenBody struct {
	Token *string `json:"token"`
}

func (a *API) verifyEmail(w http.ResponseWriter, r *http.Request) {
	var req tokenBody
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.VerifyEmail(r.Context(), str(req.Token)); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) resendVerification(w http.ResponseWriter, r *http.Request) {
	if err := a.s.ResendVerification(r.Context(), SessionFrom(r.Context()), a.meta(r)); err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, struct{}{})
}

func (a *API) passwordReset(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email *string `json:"email"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.RequestPasswordReset(r.Context(), str(req.Email), a.meta(r)); err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, struct{}{})
}

func (a *API) passwordResetConfirm(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Token       *string `json:"token"`
		NewPassword *string `json:"new_password"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.ConfirmPasswordReset(r.Context(), str(req.Token), str(req.NewPassword)); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) changePassword(w http.ResponseWriter, r *http.Request) {
	var req struct {
		CurrentPassword *string `json:"current_password"`
		NewPassword     *string `json:"new_password"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.ChangePassword(r.Context(), SessionFrom(r.Context()), str(req.CurrentPassword),
		str(req.NewPassword), a.meta(r)); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) changeEmail(w http.ResponseWriter, r *http.Request) {
	var req struct {
		NewEmail *string `json:"new_email"`
		Password *string `json:"password"`
	}
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.RequestEmailChange(r.Context(), SessionFrom(r.Context()), str(req.NewEmail), str(req.Password),
		a.meta(r)); err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, struct{}{})
}

func (a *API) emailConfirm(w http.ResponseWriter, r *http.Request) {
	var req tokenBody
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.ConfirmEmailChange(r.Context(), str(req.Token)); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) emailRevert(w http.ResponseWriter, r *http.Request) {
	var req tokenBody
	if !decode(w, r, &req) {
		return
	}
	if err := a.s.RevertEmail(r.Context(), str(req.Token)); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type passwordBody struct {
	Password *string `json:"password"`
}

func (a *API) requestDeletion(w http.ResponseWriter, r *http.Request) {
	var req passwordBody
	if !decode(w, r, &req) {
		return
	}
	purgeAt, err := a.s.RequestDeletion(r.Context(), SessionFrom(r.Context()), str(req.Password), a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]int64{"purge_at": purgeAt.Unix()})
}

func (a *API) cancelDeletion(w http.ResponseWriter, r *http.Request) {
	if err := a.s.CancelDeletion(r.Context(), SessionFrom(r.Context())); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) export(w http.ResponseWriter, r *http.Request) {
	var req passwordBody
	if !decode(w, r, &req) {
		return
	}
	body, name, err := a.s.Export(r.Context(), SessionFrom(r.Context()), str(req.Password), a.meta(r))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/json; charset=utf-8")
	h.Set("Content-Disposition", `attachment; filename="`+name+`"`)
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
