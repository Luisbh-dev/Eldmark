// Package mail composes and sends the platform's emails (plataforma.md §4.2 and §4.3).
//
// With ELDMARK_MAIL=log ([LogSender]) the email is stored in the outbound_mail table and goes to
// the log with the whole link, so tests and development get the token without a mail server; in
// staging and production it does not start. With ELDMARK_MAIL=smtp ([SMTPSender]) it goes out over
// SMTP from a background queue: the API's response time does not depend on the mail server
// (registration takes the same with a new email, one with an account or a sanctioned one).
//
// Emails are plain text in UTF-8. Headers are encoded ([mime.QEncoding]) and the recipient, already
// validated (printable ASCII only without spaces), goes in RCPT TO and in a To: written by
// [net/mail.Address]: there is no header injection.
package mail

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/logx"
)

// Template is a template's name, the one stored in outbound_mail.template.
type Template string

// Templates.
const (
	VerifyEmail      Template = "verify_email"      // when creating the account or requesting another link
	RegisterExisting Template = "register_existing" // registration (or email change) to an email with an account
	RegisterBlocked  Template = "register_blocked"  // registration with a sanctioned email (§11.2)
	ResetPassword    Template = "reset_password"    // recovering the password
	ChangeEmail      Template = "change_email"      // to the new email, to confirm it
	EmailChanged     Template = "email_changed"     // to the old email, with the revert_email link
	EmailReverted    Template = "email_reverted"    // to the recovered email, with the link to choose a password
	LoginFailures    Template = "login_failures"    // to the owner, on the 5th consecutive failure
)

// Data is a template's data.
type Data struct {
	Link     string    // link with the token
	Until    time.Time // register_blocked: until when
	NewEmail string    // email_changed: the new email, already masked
}

// Message is a composed email.
type Message struct {
	To       string
	Template Template
	Subject  string
	Body     string // plain text, with \n line breaks
	Link     string // the body's link, if there is one (for the log-mode record)
}

const signature = "\n\n— Eldmark\n\nEste correo se ha enviado automáticamente; no lo respondas.\n"

// FormatDate writes a date for the texts: "3/11/2026 18:00 UTC".
func FormatDate(t time.Time) string {
	t = t.UTC()
	return fmt.Sprintf("%d/%d/%d %02d:%02d UTC", t.Day(), int(t.Month()), t.Year(), t.Hour(), t.Minute())
}

// Compose composes a template's email.
func Compose(t Template, to string, d Data) (Message, error) {
	m := Message{To: to, Template: t, Link: d.Link}
	needsLink := true
	switch t {
	case VerifyEmail:
		m.Subject = "Verifica tu correo de Eldmark"
		m.Body = "Hola:\n\nPara terminar de crear tu cuenta de Eldmark, verifica tu correo con este enlace " +
			"(vale 24 horas):\n\n" + d.Link + "\n\nSi no has creado ninguna cuenta, ignora este mensaje."
	case RegisterExisting:
		needsLink = false
		m.Subject = "Ya tienes una cuenta de Eldmark"
		m.Body = "Hola:\n\nAlguien, seguramente tú, ha intentado usar este correo para una cuenta de Eldmark, " +
			"pero ya tienes una con él.\n\n¿Has olvidado la contraseña? Puedes recuperarla desde la pantalla " +
			"de inicio del juego, con «¿Has olvidado la contraseña?».\n\nSi no has sido tú, ignora este mensaje: " +
			"tu cuenta no ha cambiado."
	case RegisterBlocked:
		needsLink = false
		if d.Until.IsZero() {
			return Message{}, errors.New("mail: register_blocked necesita la fecha")
		}
		m.Subject = "No se ha podido crear tu cuenta de Eldmark"
		m.Body = "Hola:\n\nNo se puede crear una cuenta de Eldmark con este correo hasta el " + FormatDate(d.Until) +
			", por una sanción de una cuenta anterior con el mismo correo.\n\nSi crees que es un error, " +
			"puedes apelar como explican las normas de la comunidad."
	case ResetPassword:
		m.Subject = "Recupera tu contraseña de Eldmark"
		m.Body = "Hola:\n\nPara elegir una contraseña nueva para tu cuenta de Eldmark, abre este enlace " +
			"(vale 1 hora):\n\n" + d.Link + "\n\nSi no lo has pedido tú, ignora este mensaje: tu contraseña no cambia."
	case ChangeEmail:
		m.Subject = "Confirma tu nuevo correo de Eldmark"
		m.Body = "Hola:\n\nPara usar este correo en tu cuenta de Eldmark, confírmalo con este enlace " +
			"(vale 24 horas):\n\n" + d.Link + "\n\nSi no lo has pedido tú, ignora este mensaje: no cambiará nada."
	case EmailChanged:
		m.Subject = "El correo de tu cuenta de Eldmark ha cambiado"
		m.Body = "Hola:\n\nEl correo de tu cuenta de Eldmark ha cambiado a " + d.NewEmail + " y se han cerrado " +
			"las demás sesiones.\n\nSi has sido tú, no tienes que hacer nada.\n\nSi no has sido tú, recupera la " +
			"cuenta con este enlace (vale 7 días): la cuenta volverá a este correo, se cerrarán todas las " +
			"sesiones y elegirás una contraseña nueva.\n\n" + d.Link
	case EmailReverted:
		m.Subject = "Has recuperado tu cuenta de Eldmark"
		m.Body = "Hola:\n\nTu cuenta de Eldmark vuelve a usar este correo y se han cerrado todas las sesiones. " +
			"Elige una contraseña nueva con este enlace (vale 1 hora; si caduca, pide otro con «¿Has olvidado " +
			"la contraseña?»):\n\n" + d.Link
	case LoginFailures:
		needsLink = false
		m.Subject = "Intentos fallidos de entrar en tu cuenta de Eldmark"
		m.Body = "Hola:\n\nHa habido cinco intentos seguidos de iniciar sesión en tu cuenta de Eldmark con una " +
			"contraseña incorrecta.\n\nSi has sido tú, no tienes que hacer nada. Si no, tu cuenta sigue a salvo: " +
			"tras varios fallos los intentos se frenan. Si te preocupa, cambia la contraseña desde el juego. " +
			"No te avisaremos de nuevo hasta dentro de 24 horas."
	default:
		return Message{}, fmt.Errorf("mail: plantilla desconocida %q", t)
	}
	if needsLink && d.Link == "" {
		return Message{}, fmt.Errorf("mail: %s necesita el enlace", t)
	}
	m.Body += signature
	return m, nil
}

// Sender sends an email.
type Sender interface {
	Send(ctx context.Context, m Message) error
}

// Execer is what runs an insert: *pgxpool.Pool, pgx.Tx.
type Execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// LogSender stores the email in outbound_mail and writes it to the log with the whole link
// (ELDMARK_MAIL=log: dev and test only).
type LogSender struct {
	DB  Execer
	Log *slog.Logger
}

// Send stores the email.
func (s *LogSender) Send(ctx context.Context, m Message) error {
	if _, err := s.DB.Exec(ctx, `insert into outbound_mail (to_email, template, body) values ($1, $2, $3)`,
		m.To, string(m.Template), m.Subject+"\n\n"+m.Body); err != nil {
		return fmt.Errorf("mail: outbound_mail: %w", err)
	}
	if s.Log != nil {
		s.Log.LogAttrs(ctx, slog.LevelInfo, "correo (ELDMARK_MAIL=log)",
			slog.String("req", logx.RequestID(ctx)), slog.String("to", logx.MaskEmail(m.To)),
			slog.String("template", string(m.Template)), slog.String("link", m.Link))
	}
	return nil
}

// Recorder keeps the emails in memory (tests).
type Recorder struct {
	mu       sync.Mutex
	messages []Message
	// Err, if not nil, is what Send returns (without storing).
	Err error
}

// Send stores the email.
func (r *Recorder) Send(_ context.Context, m Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.Err != nil {
		return r.Err
	}
	r.messages = append(r.messages, m)
	return nil
}

// Messages returns a copy of the emails sent.
func (r *Recorder) Messages() []Message {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Message(nil), r.messages...)
}

// To returns the emails sent to an address.
func (r *Recorder) To(addr string) []Message {
	var out []Message
	for _, m := range r.Messages() {
		if strings.EqualFold(m.To, addr) {
			out = append(out, m)
		}
	}
	return out
}
