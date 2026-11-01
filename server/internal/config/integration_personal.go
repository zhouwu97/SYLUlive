package config

import "fmt"

func validateIntegrationPersonalConfig(enabled, personal, retired bool) error {
	if personal && (!enabled || retired) {
		return fmt.Errorf("INTEGRATION_PERSONAL_DATA_ENABLED 需要开启集成且学校个人能力未退役；不得绕过退役开关")
	}
	return nil
}
