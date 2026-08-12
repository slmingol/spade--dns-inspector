package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/miekg/dns"
)

var httpClient = &http.Client{Timeout: 8 * time.Second}

type dohResponse struct {
	Status   int           `json:"Status"`
	TC       bool          `json:"TC"`
	RD       bool          `json:"RD"`
	RA       bool          `json:"RA"`
	AD       bool          `json:"AD"`
	CD       bool          `json:"CD"`
	Question []dohQuestion `json:"Question"`
	Answer   []dohRecord   `json:"Answer,omitempty"`
}

type dohQuestion struct {
	Name string `json:"name"`
	Type int    `json:"type"`
}

type dohRecord struct {
	Name string `json:"name"`
	Type int    `json:"type"`
	TTL  int    `json:"TTL"`
	Data string `json:"data"`
}

var nameservers []string

func init() {
	cfg, err := dns.ClientConfigFromFile("/etc/resolv.conf")
	if err != nil || len(cfg.Servers) == 0 {
		nameservers = []string{"8.8.8.8:53"}
		return
	}
	port := cfg.Port
	if port == "" {
		port = "53"
	}
	for _, s := range cfg.Servers {
		// Wrap IPv6 addresses in brackets
		if net.ParseIP(s) != nil && strings.Contains(s, ":") {
			nameservers = append(nameservers, "["+s+"]:"+port)
		} else {
			nameservers = append(nameservers, s+":"+port)
		}
	}
}

func rrData(rr dns.RR) string {
	switch v := rr.(type) {
	case *dns.A:
		return v.A.String()
	case *dns.AAAA:
		return v.AAAA.String()
	case *dns.TXT:
		parts := make([]string, len(v.Txt))
		for i, t := range v.Txt {
			parts[i] = `"` + t + `"`
		}
		return strings.Join(parts, " ")
	case *dns.CAA:
		return fmt.Sprintf(`%d %s "%s"`, v.Flag, v.Tag, v.Value)
	case *dns.DS:
		return fmt.Sprintf("%d %d %d %s", v.KeyTag, v.Algorithm, v.DigestType, strings.ToUpper(v.Digest))
	case *dns.DNSKEY:
		return fmt.Sprintf("%d %d %d %s", v.Flags, v.Protocol, v.Algorithm, v.PublicKey)
	case *dns.RRSIG:
		return fmt.Sprintf("%s %d %d %d %s %s %d %s %s",
			dns.TypeToString[v.TypeCovered], v.Algorithm, v.Labels, v.OrigTtl,
			v.Expiration, v.Inception, v.KeyTag, v.SignerName, v.Signature)
	case *dns.MX:
		return fmt.Sprintf("%d %s", v.Preference, v.Mx)
	case *dns.CNAME:
		return v.Target
	case *dns.NS:
		return v.Ns
	default:
		// Strip "name TTL IN TYPE " prefix from String() output
		s := rr.String()
		fields := strings.Fields(s)
		if len(fields) > 4 {
			return strings.Join(fields[4:], " ")
		}
		return s
	}
}

func resolveHandler(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	typeStr := r.URL.Query().Get("type")
	nsOverride := r.URL.Query().Get("ns") // optional: force a specific nameserver
	if name == "" {
		http.Error(w, "missing name", http.StatusBadRequest)
		return
	}
	if typeStr == "" {
		typeStr = "A"
	}

	var qtype uint16
	if n, err := strconv.Atoi(typeStr); err == nil {
		qtype = uint16(n)
	} else {
		t, ok := dns.StringToType[strings.ToUpper(typeStr)]
		if !ok {
			http.Error(w, "invalid type: "+typeStr, http.StatusBadRequest)
			return
		}
		qtype = t
	}

	// Build nameserver list: override takes priority, then system resolvers
	resolvers := nameservers
	if nsOverride != "" {
		ns := nsOverride
		if !strings.Contains(ns, ":") {
			ns = ns + ":53"
		}
		resolvers = []string{ns}
	}

	m := new(dns.Msg)
	m.SetQuestion(dns.Fqdn(name), qtype)
	m.RecursionDesired = true
	m.SetEdns0(4096, true) // DNSSEC OK bit

	c := new(dns.Client)
	c.Net = "udp"

	var resp *dns.Msg
	var err error
	for _, ns := range resolvers {
		resp, _, err = c.Exchange(m, ns)
		if err == nil {
			break
		}
	}
	if err != nil {
		http.Error(w, "DNS query failed: "+err.Error(), http.StatusServiceUnavailable)
		return
	}

	// Retry with TCP if UDP response was truncated
	if resp.Truncated {
		tc := new(dns.Client)
		tc.Net = "tcp"
		for _, ns := range nameservers {
			r2, _, e2 := tc.Exchange(m, ns)
			if e2 == nil {
				resp = r2
				break
			}
		}
	}

	doh := dohResponse{
		Status: resp.Rcode,
		TC:     resp.Truncated,
		RD:     resp.RecursionDesired,
		RA:     resp.RecursionAvailable,
		AD:     resp.AuthenticatedData,
		CD:     resp.CheckingDisabled,
		Question: []dohQuestion{{
			Name: dns.Fqdn(name),
			Type: int(qtype),
		}},
	}
	for _, rr := range resp.Answer {
		doh.Answer = append(doh.Answer, dohRecord{
			Name: rr.Header().Name,
			Type: int(rr.Header().Rrtype),
			TTL:  int(rr.Header().Ttl),
			Data: rrData(rr),
		})
	}

	w.Header().Set("Content-Type", "application/dns-json")
	if err := json.NewEncoder(w).Encode(doh); err != nil {
		log.Printf("encode error: %v", err)
	}
}

// fetchHandler proxies HTTPS requests for well-known policy files server-side.
// Restricted to /.well-known/ paths over HTTPS to prevent SSRF abuse.
func fetchHandler(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("url")
	if raw == "" {
		http.Error(w, "missing url", http.StatusBadRequest)
		return
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" {
		http.Error(w, "url must be https", http.StatusBadRequest)
		return
	}
	if !strings.HasPrefix(u.Path, "/.well-known/") {
		http.Error(w, "only /.well-known/ paths allowed", http.StatusForbidden)
		return
	}

	req, err := http.NewRequest("GET", u.String(), nil)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", "Spade-DNS-Inspector/1.0")

	resp, err := httpClient.Do(req)
	if err != nil {
		http.Error(w, "fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		http.Error(w, "read failed", http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		// connect-src includes https: for MTA-STS policy fetch (browser-side)
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https:")
		next.ServeHTTP(w, r)
	})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "80"
	}

	log.Printf("Spade DNS Inspector — listening on :%s", port)
	if len(nameservers) > 0 {
		log.Printf("Nameservers: %s", strings.Join(nameservers, ", "))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/resolve", resolveHandler)
	mux.HandleFunc("/fetch", fetchHandler)
	mux.Handle("/", http.FileServer(http.Dir("/public")))

	if err := http.ListenAndServe(":"+port, securityHeaders(mux)); err != nil {
		log.Fatal(err)
	}
}
