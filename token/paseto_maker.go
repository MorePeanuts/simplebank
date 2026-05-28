package token

import (
	"encoding/json"
	"fmt"
	"time"

	"aidanwoods.dev/go-paseto"
)

// PasetoMaker is a Platform-Agnostic Security Tokens maker
type PasetoMaker struct {
	symmetricKey paseto.V4SymmetricKey
}

// NewPasetoMaker creates a new PasetoMaker
func NewPasetoMaker(symmetricKey string) (Maker, error) {
	key, err := paseto.V4SymmetricKeyFromBytes([]byte(symmetricKey))
	if err != nil {
		return nil, err
	}

	return &PasetoMaker{key}, nil
}

// CreateToken creates a new token for a specific username and duration
func (maker *PasetoMaker) CreateToken(username string, duration time.Duration) (string, error) {
	payload, err := NewPayload(username, duration)
	if err != nil {
		return "", err
	}

	claimsData, err := json.Marshal(*payload)
	if err != nil {
		return "", err
	}

	pasetoToken, err := paseto.NewTokenFromClaimsJSON(claimsData, nil)
	if err != nil {
		return "", err
	}
	return pasetoToken.V4Encrypt(maker.symmetricKey, nil), nil
}

// VerifyToken checks if the token is valid or not
func (maker *PasetoMaker) VerifyToken(token string) (*Payload, error) {
	parser := paseto.NewParserWithoutExpiryCheck()
	pasetoToken, err := parser.ParseV4Local(maker.symmetricKey, token, nil)
	if err != nil {
		return nil, err
	}

	payload := &Payload{}
	if err = json.Unmarshal(pasetoToken.ClaimsJSON(), payload); err != nil {
		return nil, err
	}

	if time.Now().After(payload.ExpiresAt.Time) {
		return nil, fmt.Errorf("token has expired")
	}

	return payload, nil
}
