package ai

import (
	_ "embed"
	"encoding/json"
)

type policyContractAlias struct {
	Trigger string   `json:"trigger"`
	Intent  string   `json:"intent"`
	Terms   []string `json:"terms"`
}

type policyContractFocusRule struct {
	Intent   string   `json:"intent"`
	Focus    string   `json:"focus"`
	Triggers []string `json:"triggers"`
}

type policyContractIntent struct {
	Intent                 string               `json:"intent"`
	PreferredDocumentTypes []string             `json:"preferred_document_types"`
	RequiredDocumentGroups [][]string           `json:"required_document_groups"`
	HistoricalMode         HistoricalPolicyMode `json:"historical_mode"`
	RequiredAnswerSections []string             `json:"required_answer_sections"`
	CanonicalTerms         []string             `json:"canonical_terms"`
}

type policyQueryContract struct {
	Version        string                    `json:"version"`
	IntentPriority []string                  `json:"intent_priority"`
	Aliases        []policyContractAlias     `json:"aliases"`
	FocusRules     []policyContractFocusRule `json:"focus_rules"`
	Intents        []policyContractIntent    `json:"intents"`
}

//go:embed policy_query_contract_v0.8.json
var policyQueryContractBytes []byte

var activePolicyContract = mustLoadPolicyQueryContract()

func mustLoadPolicyQueryContract() policyQueryContract {
	var contract policyQueryContract
	if err := json.Unmarshal(policyQueryContractBytes, &contract); err != nil {
		panic("invalid embedded policy query contract: " + err.Error())
	}
	if contract.Version != "v0.8" || len(contract.Intents) == 0 {
		panic("invalid embedded policy query contract version")
	}
	return contract
}

func init() {
	profiles := make(map[string]policyIntentProfile, len(activePolicyContract.Intents))
	for _, item := range activePolicyContract.Intents {
		profiles[item.Intent] = policyIntentProfile{
			preferredDocTypes: append([]string(nil), item.PreferredDocumentTypes...),
			requiredDocGroups: copyDocGroups(item.RequiredDocumentGroups),
			historicalMode:    item.HistoricalMode,
			answerMode:        item.Intent,
			answerSections:    append([]string(nil), item.RequiredAnswerSections...),
			canonicalTerms:    append([]string(nil), item.CanonicalTerms...),
		}
	}
	policyIntentProfiles = profiles
}
