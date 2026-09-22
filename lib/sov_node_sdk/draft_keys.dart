// lib/sov_node_sdk/draft_keys.dart
// ─────────────────────────────────────────────────────────────────────────────
// Centralised SharedPreferences key constants for DraftManager.
//
// Every text field that persists drafts uses a key from this class.
// Keep all draft keys here so they can be audited in one place.
// ─────────────────────────────────────────────────────────────────────────────

class DraftKeys {

  // ── SOV Speak messaging ───────────────────────────────────────────────────
  static String sovSpeak(String recipientId) =>
      'draft_sov_speak_$recipientId';
  static const String sovSpeakNew = 'draft_sov_speak_new';

  // ── SOV Vault allocation form ─────────────────────────────────────────────
  static const String vaultBeneficiaryName  = 'draft_vault_beneficiary_name';
  static const String vaultAmount           = 'draft_vault_amount';
  static const String vaultPublicStatement  = 'draft_vault_public_statement';
  static const String vaultPersonalNote     = 'draft_vault_personal_note';
  static const String vaultFamilyKey1       = 'draft_vault_family_key_1';
  static const String vaultFamilyKey1Hint   = 'draft_vault_family_key_1_hint';
  static const String vaultFamilyKey2       = 'draft_vault_family_key_2';
  static const String vaultFamilyKey2Hint   = 'draft_vault_family_key_2_hint';
  static const String vaultFamilyKey3       = 'draft_vault_family_key_3';
  static const String vaultFamilyKey3Hint   = 'draft_vault_family_key_3_hint';

  static const List<String> vaultAll = [
    vaultBeneficiaryName,
    vaultAmount,
    vaultPublicStatement,
    vaultPersonalNote,
    vaultFamilyKey1,
    vaultFamilyKey1Hint,
    vaultFamilyKey2,
    vaultFamilyKey2Hint,
    vaultFamilyKey3,
    vaultFamilyKey3Hint,
  ];

  // ── Guardian setup ────────────────────────────────────────────────────────
  static const String guardianId1 = 'draft_guardian_id_1';
  static const String guardianId2 = 'draft_guardian_id_2';
  static const String guardianId3 = 'draft_guardian_id_3';

  static const List<String> guardianAll = [
    guardianId1,
    guardianId2,
    guardianId3,
  ];

  // ── Send SOV screen ───────────────────────────────────────────────────────
  static const String sendRecipientId = 'draft_send_recipient_id';
  static const String sendAmount      = 'draft_send_amount';
  static const String sendNote        = 'draft_send_note';

  static const List<String> sendAll = [
    sendRecipientId,
    sendAmount,
    sendNote,
  ];

  // ── Exchange create order ─────────────────────────────────────────────────
  static const String exchangeAmount      = 'draft_exchange_amount';
  static const String exchangeDescription = 'draft_exchange_description';

  static const List<String> exchangeAll = [
    exchangeAmount,
    exchangeDescription,
  ];

  // ── Governance poll creation ──────────────────────────────────────────────
  static const String governanceQuestion = 'draft_governance_question';
  static const String governanceOption1  = 'draft_governance_option_1';
  static const String governanceOption2  = 'draft_governance_option_2';
  static const String governanceOption3  = 'draft_governance_option_3';

  static const List<String> governanceAll = [
    governanceQuestion,
    governanceOption1,
    governanceOption2,
    governanceOption3,
  ];

  // ── Forum post composition ────────────────────────────────────────────────
  static String forumPost(String channelId) => 'draft_forum_post_$channelId';
  static const String forumPostNew = 'draft_forum_post_new';

  // ── SOV Vault claim stage 2 ───────────────────────────────────────────────
  static const String claimFamilyKeyword  = 'draft_claim_family_keyword';
  static const String claimFamilyKeyword2 = 'draft_claim_family_keyword_2';
  static const String claimFamilyKeyword3 = 'draft_claim_family_keyword_3';
  static const String claimStatement      = 'draft_claim_statement';

  static const List<String> claimAll = [
    claimFamilyKeyword,
    claimFamilyKeyword2,
    claimFamilyKeyword3,
    claimStatement,
  ];

  // ── Justice Protocol — dispute filing ────────────────────────────────────
  static const String justiceDefendantId  = 'draft_justice_defendant_id';
  static const String justiceEvidenceHash = 'draft_justice_evidence_hash';
  static const String justiceClaimAmount  = 'draft_justice_claim_amount';

  static const List<String> justiceAll = [
    justiceDefendantId,
    justiceEvidenceHash,
    justiceClaimAmount,
  ];

  // ── SOV Value voting ──────────────────────────────────────────────────────
  static const String sovValueProposal = 'draft_sov_value_proposal';

  // ── Profile / Settings editable fields ───────────────────────────────────
  static const String profileNote = 'draft_profile_note';

  // ── Home screen preferences ───────────────────────────────────────────────
  // Not a draft — this is a persistent display preference.
  // Stored here for a single-source audit of all SharedPreferences keys.
  static const String balanceVisible = 'balance_visible_preference';
}
