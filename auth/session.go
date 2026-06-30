package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

type sessionEntry struct {
	projectID string
	expiry    time.Time
}

type sessionStore struct {
	mu  sync.Map
	ttl time.Duration
}

func newSessionStore(ttl time.Duration) *sessionStore {
	s := &sessionStore{ttl: ttl}
	go s.sweepLoop()
	return s
}

// create generates a new session ID, stores it, and returns the ID.
func (s *sessionStore) create(projectID string) string {
	b := make([]byte, 16)
	rand.Read(b)
	id := hex.EncodeToString(b)
	s.mu.Store(id, &sessionEntry{
		projectID: projectID,
		expiry:    time.Now().Add(s.ttl),
	})
	return id
}

// valid returns true if the session ID exists and has not expired.
func (s *sessionStore) valid(id string) bool {
	v, ok := s.mu.Load(id)
	if !ok {
		return false
	}
	e := v.(*sessionEntry)
	if time.Now().After(e.expiry) {
		s.mu.Delete(id)
		return false
	}
	return true
}

// delete removes a session (logout).
func (s *sessionStore) delete(id string) {
	s.mu.Delete(id)
}

// sweepLoop removes expired sessions every 5 minutes.
func (s *sessionStore) sweepLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		s.mu.Range(func(k, v any) bool {
			if now.After(v.(*sessionEntry).expiry) {
				s.mu.Delete(k)
			}
			return true
		})
	}
}
