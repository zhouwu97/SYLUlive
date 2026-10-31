package config

import (
	"github.com/stretchr/testify/require"
	"testing"
)

func TestIntegrationConfigFailClosed(t *testing.T) {
	for _, origin := range []string{"", "http://remote.invalid", "https://user:secret@host", "https://host/web", "https://host?x=y", "https://host#fragment"} {
		require.Error(t, validateIntegrationConfig(true, false, false, origin, false), origin)
	}
	require.NoError(t, validateIntegrationConfig(true, true, true, "https://fixture.invalid", true))
	require.NoError(t, validateIntegrationConfig(true, false, false, "http://127.0.0.1:5173", false))
	require.Error(t, validateIntegrationConfig(true, false, false, "http://127.0.0.1:5173", true))
	require.Error(t, validateIntegrationConfig(false, true, false, "", false))
	require.Error(t, validateIntegrationConfig(true, false, true, "https://fixture.invalid", false))
	setBaseConfigEnv(t, "debug")
	t.Setenv("INTEGRATIONS_ENABLED", "")
	t.Setenv("INTEGRATION_PROPOSALS_ENABLED", "")
	t.Setenv("INTEGRATION_OWNER_PUBLISH_ENABLED", "")
	c := Load()
	require.False(t, c.IntegrationsEnabled)
	require.False(t, c.IntegrationProposalsEnabled)
	require.False(t, c.IntegrationOwnerPublishEnabled)
}
