package config

import "fmt"

// validateIntegrationPersonalConfig 让本人成绩／二课能力失败关闭：必须开启集成，且学校个人能力未退役。
func validateIntegrationPersonalConfig(enabled, personal, retired bool) error {
	if personal && (!enabled || retired) {
		return fmt.Errorf("INTEGRATION_PERSONAL_DATA_ENABLED 需要开启集成且学校个人能力未退役；不得绕过退役开关")
	}
	return nil
}
