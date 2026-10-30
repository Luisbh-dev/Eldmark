package accounts

import (
	"bytes"
	"errors"
	"html/template"
	"net/http"

	"eldmark/platform/internal/httpx"
)

// Las páginas de los enlaces de los correos (§4.3): /verify, /reset y /revert, fuera de /v1 y sin
// la regla del 426. El GET sirve un formulario mínimo (html/template, sin JavaScript ni CSS) con el
// token en un campo oculto, que hace POST application/x-www-form-urlencoded a la misma ruta; así
// un escáner de correo que abre el enlace no lo gasta. El token se valida (43 caracteres
// base64url) antes de pintarlo; si no vale, la página dice «Enlace no válido» sin repetirlo. Por
// dentro llaman a las mismas funciones que /v1. /verify vale para verify_email y change_email.

var pageTemplate = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>{{.Title}} · Eldmark</title>
</head>
<body>
<h1>{{.Title}}</h1>
{{range .Paragraphs}}<p>{{.}}</p>
{{end}}{{if .Form}}<form method="post" action="{{.Action}}">
<input type="hidden" name="token" value="{{.Token}}">
{{if .Password}}<p><label>Contraseña nueva (de 10 a 128 caracteres)<br>
<input type="password" name="new_password" minlength="10" maxlength="128" required autocomplete="new-password"></label></p>
<p><label>Repite la contraseña<br>
<input type="password" name="new_password_repeat" minlength="10" maxlength="128" required autocomplete="new-password"></label></p>
{{end}}<p><button type="submit">{{.Button}}</button></p>
</form>
{{end}}</body>
</html>
`))

type page struct {
	Title      string
	Paragraphs []string
	Form       bool
	Action     string
	Token      string
	Password   bool
	Button     string
}

func writePage(w http.ResponseWriter, status int, p page) {
	var buf bytes.Buffer
	if err := pageTemplate.Execute(&buf, p); err != nil {
		status = http.StatusInternalServerError
		buf.Reset()
		buf.WriteString("Error del servidor")
	}
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Security-Policy", "default-src 'none'; form-action 'self'")
	h.Set("X-Frame-Options", "DENY")
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

var invalidLinkPage = page{Title: "Enlace no válido",
	Paragraphs: []string{"Este enlace no es válido. Copia el enlace entero del correo o pide otro desde el juego."}}

// pageSpec describe una de las tres páginas.
type pageSpec struct {
	path, title, intro, button string
	password                   bool
	submit                     func(a *API, r *http.Request, token string) (page, error)
}

var pageSpecs = []pageSpec{
	{path: "/verify", title: "Confirmar el correo", button: "Confirmar",
		intro: "Pulsa el botón para confirmar este correo en tu cuenta de Eldmark.",
		submit: func(a *API, r *http.Request, token string) (page, error) {
			result, err := a.s.ConfirmLink(r.Context(), token)
			if err != nil {
				return page{}, err
			}
			if result == LinkChanged {
				return page{Title: "Correo cambiado", Paragraphs: []string{
					"Tu cuenta usa ya este correo. Ya puedes cerrar esta página y volver a entrar en el juego."}}, nil
			}
			return page{Title: "Correo verificado", Paragraphs: []string{"Correo verificado. Ya puedes cerrar esta página."}}, nil
		}},
	{path: "/reset", title: "Elegir una contraseña nueva", button: "Cambiar la contraseña", password: true,
		intro: "Escribe la contraseña nueva de tu cuenta de Eldmark. Se cerrarán todas las sesiones abiertas.",
		submit: func(a *API, r *http.Request, token string) (page, error) {
			pw := r.PostFormValue("new_password")
			if pw != r.PostFormValue("new_password_repeat") {
				return page{}, errValidation(map[string]string{"new_password": "mismatch"})
			}
			if err := a.s.ConfirmPasswordReset(r.Context(), token, pw); err != nil {
				return page{}, err
			}
			return page{Title: "Contraseña cambiada", Paragraphs: []string{
				"Ya puedes cerrar esta página y entrar en el juego con la contraseña nueva."}}, nil
		}},
	{path: "/revert", title: "Recuperar tu correo", button: "Recuperar la cuenta",
		intro: "Si no has cambiado tú el correo de tu cuenta de Eldmark, pulsa el botón: la cuenta volverá a " +
			"este correo, se cerrarán todas las sesiones y te mandaremos un enlace para elegir una contraseña nueva.",
		submit: func(a *API, r *http.Request, token string) (page, error) {
			if err := a.s.RevertEmail(r.Context(), token); err != nil {
				return page{}, err
			}
			return page{Title: "Cuenta recuperada", Paragraphs: []string{
				"Tu cuenta vuelve a usar este correo y se han cerrado todas las sesiones.",
				"Te hemos mandado un correo con un enlace para elegir una contraseña nueva (vale 1 hora)."}}, nil
		}},
}

func (a *API) mountPages(r Router) {
	for _, spec := range pageSpecs {
		r.HandlePublic("GET "+spec.path, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			token := req.URL.Query().Get("token")
			if !ValidToken(token) {
				writePage(w, http.StatusBadRequest, invalidLinkPage)
				return
			}
			writePage(w, http.StatusOK, spec.form(token, ""))
		}))
		r.HandlePublic("POST "+spec.path, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			req.Body = http.MaxBytesReader(w, req.Body, httpx.PublicBodyLimit)
			if err := req.ParseForm(); err != nil {
				writePage(w, http.StatusBadRequest, invalidLinkPage)
				return
			}
			token := req.PostFormValue("token")
			if !ValidToken(token) {
				writePage(w, http.StatusBadRequest, invalidLinkPage)
				return
			}
			done, err := spec.submit(a, req, token)
			if err == nil {
				writePage(w, http.StatusOK, done)
				return
			}
			var e *httpx.Error
			if !errors.As(err, &e) {
				a.fail(w, req, err) // registra el error
				return
			}
			status := e.Status
			switch {
			case e.Fields["new_password"] != "":
				writePage(w, status, spec.form(token, passwordProblemText(e.Fields["new_password"])))
			case e.Fields["token"] == "used":
				writePage(w, status, page{Title: "Enlace ya usado", Paragraphs: []string{
					"Este enlace ya se ha usado. Si lo necesitas, pide otro desde el juego."}})
			case e.Fields["token"] == "expired":
				writePage(w, status, page{Title: "Enlace caducado", Paragraphs: []string{
					"Este enlace ha caducado. Pide otro desde el juego."}})
			case e.Fields["token"] == "unavailable":
				writePage(w, status, page{Title: "Correo en uso", Paragraphs: []string{
					"Ese correo lo usa ya otra cuenta, así que el enlace no se puede aplicar."}})
			case e.Status >= 500:
				writePage(w, status, page{Title: "Error del servidor", Paragraphs: []string{e.Message}})
			default:
				writePage(w, status, invalidLinkPage)
			}
		}))
	}
}

func (spec pageSpec) form(token, problem string) page {
	p := page{Title: spec.title, Paragraphs: []string{spec.intro}, Form: true, Action: spec.path, Token: token,
		Password: spec.password, Button: spec.button}
	if problem != "" {
		p.Paragraphs = append(p.Paragraphs, problem)
	}
	return p
}

func passwordProblemText(reason string) string {
	switch reason {
	case "mismatch":
		return "Las dos contraseñas no coinciden."
	case "too_short":
		return "La contraseña tiene que tener al menos 10 caracteres."
	case "too_long":
		return "La contraseña puede tener como mucho 128 caracteres."
	case "same_as_email":
		return "La contraseña no puede ser tu correo."
	}
	return "La contraseña no vale."
}
