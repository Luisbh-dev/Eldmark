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

// QueueSize is how many emails wait at most in the [SMTPSender] queue; with the queue full, Send
// returns an error (which is logged) instead of blocking the request.
const QueueSize = 1000

// Attempts for each send and the wait between them.
var retryWaits = []time.Duration{2 * time.Second, 10 * time.Second}

// SMTPSender sends over SMTP from a background queue (ELDMARK_MAIL=smtp). With smtp:// it uses
// STARTTLS, which it requires except toward loopback; with smtps://, TLS from the start.
type SMTPSender struct {
	url      *url.URL
	from     netmail.Address
	log      *slog.Logger
	queue    chan Message
	dial     func(ctx context.Context, network, addr string) (net.Conn, error) // net.Dialer; tests change it
	timeout  time.Duration
	wg       sync.WaitGroup
	start    sync.Once
	stopOnce sync.Once
	stop     chan struct{}
}

// NewSMTP prepares sending through the server in smtpURL (smtp://user:password@host:587) with the
// sender from (an address).
func NewSMTP(smtpURL *url.URL, from string, log *slog.Logger) (*SMTPSender, error) {
	if smtpURL == nil || (smtpURL.Scheme != "smtp" && smtpURL.Scheme != "smtps") || smtpURL.Hostname() == "" {
		return nil, errors.New("mail: la URL de SMTP no vale")
	}
	addr, err := netmail.ParseAddress(from)
	if err != nil || addr.Name != "" || strings.ContainsAny(from, "\r\n") {
		return nil, errors.New("mail: el remitente no es una dirección válida")
	}
	const timeout = 30 * time.Second
	return &SMTPSender{url: smtpURL, from: netmail.Address{Name: "Eldmark", Address: addr.Address}, log: log,
		queue: make(chan Message, QueueSize), dial: (&net.Dialer{Timeout: timeout}).DialContext, timeout: timeout,
		stop: make(chan struct{})}, nil
}

// Start starts the sending in the background until Close.
func (s *SMTPSender) Start() {
	s.start.Do(func() {
		s.wg.Add(1)
		go s.run()
	})
}

// Close stops accepting emails, tries to send those left in the queue (without retries) and waits
// for it to finish.
func (s *SMTPSender) Close() {
	s.stopOnce.Do(func() { close(s.stop) })
	s.wg.Wait()
}

// Send enqueues the email. It does not wait for the server: with the queue full it returns an
// error.
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
				// On stopping we do not wait: one last attempt.
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
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	tlsConfig := &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}
	conn, err := s.dial(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(deadline)
	if s.url.Scheme == "smtps" {
		secure := tls.Client(conn, tlsConfig)
		if err := secure.HandshakeContext(ctx); err != nil {
			return err
		}
		conn = secure
	}
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

// BuildMIME writes the whole email (headers and body) in plain UTF-8 text with quoted-printable. It
// rejects a recipient or a sender with line breaks, even though the API already rejects them
// earlier.
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

// Close of a Sender that needs it (SMTPSender); the rest do nothing.
func Close(s Sender) {
	if c, ok := s.(interface{ Close() }); ok {
		c.Close()
	}
}
