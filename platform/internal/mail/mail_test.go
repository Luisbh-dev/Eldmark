package mail

import (
	"bufio"
	"bytes"
	"context"
	"io"
	"mime"
	"mime/quotedprintable"
	"net"
	netmail "net/mail"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestComposeEveryTemplate(t *testing.T) {
	link := "http://127.0.0.1:24680/verify?token=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	data := Data{Link: link, Until: time.Date(2026, 11, 3, 18, 0, 0, 0, time.UTC), NewEmail: "n***@example.org"}
	for _, tpl := range []Template{VerifyEmail, RegisterExisting, RegisterBlocked, ResetPassword, ChangeEmail,
		EmailChanged, EmailReverted, LoginFailures} {
		m, err := Compose(tpl, "aneira@example.org", data)
		if err != nil {
			t.Fatalf("%s: %v", tpl, err)
		}
		if m.Subject == "" || !strings.HasSuffix(m.Body, signature) || m.Template != tpl {
			t.Errorf("%s: %+v", tpl, m)
		}
		hasLink := strings.Contains(m.Body, link)
		wantLink := tpl != RegisterExisting && tpl != RegisterBlocked && tpl != LoginFailures
		if hasLink != wantLink {
			t.Errorf("%s: link in the body %v", tpl, hasLink)
		}
	}
	m, _ := Compose(RegisterBlocked, "a@example.org", data)
	if !strings.Contains(m.Body, "3/11/2026 18:00 UTC") {
		t.Errorf("lockout date: %s", m.Body)
	}
	if _, err := Compose(VerifyEmail, "a@example.org", Data{}); err == nil {
		t.Error("verify_email without a link")
	}
	if _, err := Compose("otra", "a@example.org", data); err == nil {
		t.Error("unknown template")
	}
}

func TestBuildMIME(t *testing.T) {
	from := netmail.Address{Name: "Eldmark", Address: "no-reply@eldmark.example"}
	m, _ := Compose(ResetPassword, "aneira@example.org", Data{Link: "https://eldmark.example/reset?token=x"})
	data, err := BuildMIME(from, m, time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	msg, err := netmail.ReadMessage(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	subject, err := new(mime.WordDecoder).DecodeHeader(msg.Header.Get("Subject"))
	if err != nil || subject != "Recupera tu contraseña de Eldmark" {
		t.Fatalf("subject: %q %v (%s)", subject, err, msg.Header.Get("Subject"))
	}
	if strings.Contains(msg.Header.Get("Subject"), "ñ") {
		t.Fatal("the subject is encoded")
	}
	if msg.Header.Get("To") != "<aneira@example.org>" || !strings.Contains(msg.Header.Get("From"), "no-reply@eldmark.example") {
		t.Fatalf("addresses: %q %q", msg.Header.Get("To"), msg.Header.Get("From"))
	}
	body, _ := io.ReadAll(quotedprintable.NewReader(msg.Body))
	if !strings.Contains(string(body), "https://eldmark.example/reset?token=x") || !strings.Contains(string(body), "contraseña") {
		t.Fatalf("body: %s", body)
	}
	// Only known headers: nothing coming from the recipient opens a new header.
	for _, bad := range []string{"aneira@example.org\r\nBcc: otro@example.org", "a@example.org\nBcc: b@example.org"} {
		m.To = bad
		if _, err := BuildMIME(from, m, time.Now()); err == nil {
			t.Errorf("recipient with a line break: %q", bad)
		}
	}
	m.To = "Nombre <a@example.org>"
	if _, err := BuildMIME(from, m, time.Now()); err == nil {
		t.Error("the recipient is only the address")
	}
}

// fakeSMTP is a minimal SMTP server on loopback, without TLS or authentication.
type fakeSMTP struct {
	ln   net.Listener
	mu   sync.Mutex
	from []string
	rcpt []string
	data []string
}

func newFakeSMTP(t *testing.T) *fakeSMTP {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeSMTP{ln: ln}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeSMTP) serve(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	reply := func(s string) { _, _ = conn.Write([]byte(s + "\r\n")) }
	reply("220 prueba")
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return
		}
		cmd := strings.ToUpper(strings.TrimSpace(line))
		switch {
		case strings.HasPrefix(cmd, "EHLO"):
			reply("250-prueba")
			reply("250 8BITMIME")
		case strings.HasPrefix(cmd, "MAIL FROM"):
			f.mu.Lock()
			f.from = append(f.from, strings.TrimSpace(line))
			f.mu.Unlock()
			reply("250 ok")
		case strings.HasPrefix(cmd, "RCPT TO"):
			f.mu.Lock()
			f.rcpt = append(f.rcpt, strings.TrimSpace(line))
			f.mu.Unlock()
			reply("250 ok")
		case cmd == "DATA":
			reply("354 adelante")
			var b strings.Builder
			for {
				l, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if l == ".\r\n" {
					break
				}
				b.WriteString(l)
			}
			f.mu.Lock()
			f.data = append(f.data, b.String())
			f.mu.Unlock()
			reply("250 recibido")
		case cmd == "QUIT":
			reply("221 adiós")
			return
		default:
			reply("250 ok")
		}
	}
}

func (f *fakeSMTP) received() ([]string, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.rcpt...), append([]string(nil), f.data...)
}

func TestSMTPSenderDelivers(t *testing.T) {
	server := newFakeSMTP(t)
	u, _ := url.Parse("smtp://" + server.ln.Addr().String())
	s, err := NewSMTP(u, "no-reply@eldmark.example", nil)
	if err != nil {
		t.Fatal(err)
	}
	s.Start()
	m, _ := Compose(VerifyEmail, "aneira@example.org", Data{Link: "http://x/verify?token=y"})
	if err := s.Send(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	s.Close()
	rcpt, data := server.received()
	if len(rcpt) != 1 || rcpt[0] != "RCPT TO:<aneira@example.org>" || len(data) != 1 ||
		!strings.Contains(data[0], "Subject: Verifica tu correo de Eldmark\r\n") {
		t.Fatalf("received: %v %v", rcpt, data)
	}
	if err := s.Send(context.Background(), m); err == nil {
		t.Fatal("after Close it does not accept emails")
	}
	if _, err := NewSMTP(u, "Nombre <a@b.c>", nil); err == nil {
		t.Fatal("the sender is only the address")
	}
}

// Without STARTTLS, only toward loopback: nothing is sent in the clear to another machine. The URL
// names another machine and the connection is diverted to the fake server (which does not offer
// STARTTLS): the send is refused before MAIL FROM. With smtps://, a server without TLS does not
// receive anything either.
func TestSMTPRequiresStartTLSOutsideLoopback(t *testing.T) {
	if isLoopback("smtp.example.org") || !isLoopback("127.0.0.1") || !isLoopback("::1") || !isLoopback("localhost") {
		t.Fatal("isLoopback")
	}
	server := newFakeSMTP(t)
	m, _ := Compose(ResetPassword, "aneira@example.org", Data{Link: "https://eldmark.example/reset?token=secreto"})
	for _, raw := range []string{"smtp://smtp.example.org:25", "smtps://smtp.example.org"} {
		u, _ := url.Parse(raw)
		s, err := NewSMTP(u, "no-reply@eldmark.example", nil)
		if err != nil {
			t.Fatal(err)
		}
		var dialed string
		s.dial = func(ctx context.Context, network, addr string) (net.Conn, error) {
			dialed = addr
			return (&net.Dialer{}).DialContext(ctx, network, server.ln.Addr().String())
		}
		err = s.deliver(m)
		if err == nil || (strings.HasPrefix(raw, "smtp:") && err.Error() != "el servidor SMTP no ofrece STARTTLS") {
			t.Fatalf("%s: %v", raw, err)
		}
		if want := map[bool]string{true: "smtp.example.org:25", false: "smtp.example.org:465"}[strings.HasPrefix(raw, "smtp:")]; dialed != want {
			t.Fatalf("%s: connected to %q", raw, dialed)
		}
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	if len(server.from)+len(server.rcpt)+len(server.data) != 0 {
		t.Fatalf("it went out in the clear: %v %v %v", server.from, server.rcpt, server.data)
	}
}
