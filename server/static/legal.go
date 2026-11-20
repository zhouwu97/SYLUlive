package staticassets

import "embed"

// LegalPages follows the App's legal document source. Embedding keeps public
// documents available in binary-only and container deployments.
//
//go:embed legal/*.html
var LegalPages embed.FS
