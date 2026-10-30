// Package mail compone y envía los correos de la plataforma (plataforma.md §4.2 y §4.3).
//
// Con ELDMARK_MAIL=log ([LogSender]) el correo se guarda en la tabla outbound_mail y va al
// registro con el enlace entero, así las pruebas y el desarrollo sacan el token sin servidor de
// correo; en staging y production no arranca. Con ELDMARK_MAIL=smtp ([SMTPSender]) sale por SMTP
// desde una cola en segundo plano: el tiempo de respuesta de la API no depende del servidor de
// correo (el registro tarda lo mismo con un correo nuevo, uno con cuenta o uno sancionado).
//
// Los correos son texto plano en UTF-8. Las cabeceras van codificadas ([mime.QEncoding]) y el
// destinatario, ya validado (solo ASCII imprimible sin espacios), va en RCPT TO y en un To:
// escrito por [net/mail.Address]: no hay inyección de cabeceras.
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

// Template es el nombre de una plantilla, el que se guarda en outbound_mail.template.
type Template string

// Plantillas.
const (
	VerifyEmail      Template = "verify_email"      // al crear la cuenta o al pedir otro enlace
	RegisterExisting Template = "register_existing" // registro (o cambio de correo) hacia un correo con cuenta
	RegisterBlocked  Template = "register_blocked"  // registro con un correo sancionado (§11.2)
	ResetPassword    Template = "reset_password"    // recuperar la contraseña
	ChangeEmail      Template = "change_email"      // al correo nuevo, para confirmarlo
	EmailChanged     Template = "email_changed"     // al correo viejo, con el enlace revert_email
	EmailReverted    Template = "email_reverted"    // al correo recuperado, con el enlace para elegir contraseña
	LoginFailures    Template = "login_failures"    // al dueño, al 5.º fallo seguido
)

// Data son los datos de una plantilla.
type Data struct {
	Link     string    // enlace con el token
	Until    time.Time // register_blocked: hasta cuándo
	NewEmail string    // email_changed: el correo nuevo, ya enmascarado
}

// Message es un correo compuesto.
type Message struct {
	To       string
	Template Template
	Subject  string
	Body     string // texto plano, con saltos \n
	Link     string // el enlace del cuerpo, si lo hay (para el registro del modo log)
}

const signature = "\n\n— Eldmark\n\nEste correo se ha enviado automáticamente; no lo respondas.\n"

// FormatDate escribe una fecha para los textos: «3/11/2026 18:00 UTC».
func FormatDate(t time.Time) string {
	t = t.UTC()
	return fmt.Sprintf("%d/%d/%d %02d:%02d UTC", t.Day(), int(t.Month()), t.Year(), t.Hour(), t.Minute())
}

// Compose compone el correo de una plantilla.
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

// Sender envía un correo.
type Sender interface {
	Send(ctx context.Context, m Message) error
}

// Execer es lo que ejecuta un insert: *pgxpool.Pool, pgx.Tx.
type Execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// LogSender guarda el correo en outbound_mail y lo escribe en el registro con el enlace entero
// (ELDMARK_MAIL=log: solo dev y test).
type LogSender struct {
	DB  Execer
	Log *slog.Logger
}

// Send guarda el correo.
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

// Recorder guarda los correos en memoria (pruebas).
type Recorder struct {
	mu       sync.Mutex
	messages []Message
	// Err, si no es nil, es lo que devuelve Send (sin guardar).
	Err error
}

// Send guarda el correo.
func (r *Recorder) Send(_ context.Context, m Message) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.Err != nil {
		return r.Err
	}
	r.messages = append(r.messages, m)
	return nil
}

// Messages devuelve una copia de los correos enviados.
func (r *Recorder) Messages() []Message {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]Message(nil), r.messages...)
}

// To devuelve los correos enviados a una dirección.
func (r *Recorder) To(addr string) []Message {
	var out []Message
	for _, m := range r.Messages() {
		if strings.EqualFold(m.To, addr) {
			out = append(out, m)
		}
	}
	return out
}
