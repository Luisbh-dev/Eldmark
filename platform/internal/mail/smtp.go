package mail

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"log/slog"
	"mime"
	"mime/quotedprintable"
	"net"
	netmail "net/mail"
	"net/netip"
	"net/smtp"
	"net/url"
	"strings"
	"sync"
	"time"

	"eldmark/platform/internal/logx"
)

// QueueSize es cuántos correos esperan como mucho en la cola de [SMTPSender]; con la cola llena,
// Send devuelve un error (que se registra) en lugar de bloquear la petición.
const QueueSize = 1000

// Intentos de cada envío y espera entre ellos.
var retryWaits = []time.Duration{2 * time.Second, 10 * time.Second}

// SMTPSender envía por SMTP desde una cola en segundo plano (ELDMARK_MAIL=smtp). Con smtp:// usa
// STARTTLS, que exige salvo hacia loopback; con smtps://, TLS desde el principio.
type SMTPSender struct {
	url      *url.URL
	from     netmail.Address
	log      *slog.Logger
	queue    chan Message
	dialer   net.Dialer
	timeout  time.Duration
	wg       sync.WaitGroup
	start    sync.Once
	stopOnce sync.Once
	stop     chan struct{}
}

// NewSMTP prepara el envío por el servidor de smtpURL (smtp://usuario:clave@host:587) con el
// remitente from (una dirección).
func NewSMTP(smtpURL *url.URL, from string, log *slog.Logger) (*SMTPSender, error) {
	if smtpURL == nil || (smtpURL.Scheme != "smtp" && smtpURL.Scheme != "smtps") || smtpURL.Hostname() == "" {
		return nil, errors.New("mail: la URL de SMTP no vale")
	}
	addr, err := netmail.ParseAddress(from)
	if err != nil || addr.Name != "" || strings.ContainsAny(from, "\r\n") {
		return nil, errors.New("mail: el remitente no es una dirección válida")
	}
	return &SMTPSender{url: smtpURL, from: netmail.Address{Name: "Eldmark", Address: addr.Address}, log: log,
		queue: make(chan Message, QueueSize), timeout: 30 * time.Second, stop: make(chan struct{})}, nil
}

// Start arranca el envío en segundo plano hasta Close.
func (s *SMTPSender) Start() {
	s.start.Do(func() {
		s.wg.Add(1)
		go s.run()
	})
}

// Close deja de aceptar correos, intenta enviar los que quedan en la cola (sin reintentos) y
// espera a que termine.
func (s *SMTPSender) Close() {
	s.stopOnce.Do(func() { close(s.stop) })
	s.wg.Wait()
}

// Send encola el correo. No espera al servidor: con la cola llena devuelve un error.
func (s *SMTPSender) Send(_ context.Context, m Message) error {
	select {
	case <-s.stop:
		return errors.New("mail: el envío está parado")
	default:
	}
	select {
	case s.queue <- m:
		return nil
	default:
		return errors.New("mail: la cola de correo está llena")
	}
}

func (s *SMTPSender) run() {
	defer s.wg.Done()
	for {
		select {
		case m := <-s.queue:
			s.deliverWithRetries(m, true)
		case <-s.stop:
			for {
				select {
				case m := <-s.queue:
					s.deliverWithRetries(m, false)
				default:
					return
				}
			}
		}
	}
}

func (s *SMTPSender) deliverWithRetries(m Message, retry bool) {
	attempts := 1
	if retry {
		attempts += len(retryWaits)
	}
	var err error
	for i := 0; i < attempts; i++ {
		if i > 0 {
			select {
			case <-time.After(retryWaits[i-1]):
			case <-s.stop:
				// Al parar no se espera: un último intento.
			}
		}
		if err = s.deliver(m); err == nil {
			return
		}
	}
	if s.log != nil {
		s.log.Error("no se ha podido enviar un correo", "to", logx.MaskEmail(m.To), "template", string(m.Template),
			"err", err.Error())
	}
}

func (s *SMTPSender) deliver(m Message) error {
	host := s.url.Hostname()
	port := s.url.Port()
	if port == "" {
		port = "587"
		if s.url.Scheme == "smtps" {
			port = "465"
		}
	}
	addr := net.JoinHostPort(host, port)
	deadline := time.Now().Add(s.timeout)
	tlsConfig := &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	var conn net.Conn
	var err error
	if s.url.Scheme == "smtps" {
		conn, err = tls.DialWithDialer(&net.Dialer{Timeout: s.timeout}, "tcp", addr, tlsConfig)
	} else {
		conn, err = s.dialer.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(deadline)
	c, err := smtp.NewClient(conn, host)
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Hello(domainOf(s.from.Address)); err != nil {
		return err
	}
	if s.url.Scheme == "smtp" {
		if ok, _ := c.Extension("STARTTLS"); ok {
			if err := c.StartTLS(tlsConfig); err != nil {
				return err
			}
		} else if !isLoopback(host) {
			return errors.New("el servidor SMTP no ofrece STARTTLS")
		}
	}
	if s.url.User != nil {
		password, _ := s.url.User.Password()
		if err := c.Auth(smtp.PlainAuth("", s.url.User.Username(), password, host)); err != nil {
			return err
		}
	}
	data, err := BuildMIME(s.from, m, time.Now())
	if err != nil {
		return err
	}
	if err := c.Mail(s.from.Address); err != nil {
		return err
	}
	if err := c.Rcpt(m.To); err != nil {
		return err
	}
	w, err := c.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(data); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return c.Quit()
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	a, err := netip.ParseAddr(host)
	return err == nil && a.IsLoopback()
}

func domainOf(addr string) string {
	if at := strings.LastIndexByte(addr, '@'); at >= 0 {
		return addr[at+1:]
	}
	return "localhost"
}

// BuildMIME escribe el correo entero (cabeceras y cuerpo) en texto plano UTF-8 con
// quoted-printable. Rechaza un destinatario o un remitente con saltos de línea, aunque la API ya
// los rechaza antes.
func BuildMIME(from netmail.Address, m Message, date time.Time) ([]byte, error) {
	for _, v := range []string{from.Name, from.Address, m.To} {
		if strings.ContainsAny(v, "\r\n") {
			return nil, errors.New("mail: salto de línea en una dirección")
		}
	}
	to, err := netmail.ParseAddress(m.To)
	if err != nil || to.Address != m.To {
		return nil, errors.New("mail: el destinatario no es una dirección válida")
	}
	var id [12]byte
	_, _ = rand.Read(id[:])
	var b bytes.Buffer
	header := func(name, value string) { b.WriteString(name + ": " + value + "\r\n") }
	header("From", from.String())
	header("To", (&netmail.Address{Address: to.Address}).String())
	header("Subject", mime.QEncoding.Encode("utf-8", m.Subject))
	header("Date", date.UTC().Format(time.RFC1123Z))
	header("Message-ID", "<"+hex.EncodeToString(id[:])+"@"+domainOf(from.Address)+">")
	header("MIME-Version", "1.0")
	header("Content-Type", "text/plain; charset=utf-8")
	header("Content-Transfer-Encoding", "quoted-printable")
	header("Auto-Submitted", "auto-generated")
	b.WriteString("\r\n")
	qp := quotedprintable.NewWriter(&b)
	if _, err := qp.Write([]byte(strings.ReplaceAll(m.Body, "\r\n", "\n"))); err != nil {
		return nil, err
	}
	if err := qp.Close(); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// Close de un Sender que lo necesita (SMTPSender); el resto no hace nada.
func Close(s Sender) {
	if c, ok := s.(interface{ Close() }); ok {
		c.Close()
	}
}
