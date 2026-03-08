// Source of truth for all events. Contract events, webhook payloads,
// SDK event types, and Ponder handlers all generate from this.

export enum EventType {
  // Escrow
  ESCROW_FUNDED = "escrow.funded",
  ESCROW_RELEASED = "escrow.released",
  ESCROW_TIMEOUT = "escrow.timeout",
  ESCROW_CANCELLED = "escrow.cancelled",
  ESCROW_DISPUTED = "escrow.disputed",
  MILESTONE_RELEASED = "milestone.released",
  CLAIM_START_CONFIRMED = "claim_start.confirmed",

  // Metered
  TAB_OPENED = "tab.opened",
  TAB_CHARGE = "tab.charge",
  TAB_CLOSED = "tab.closed",
  TAB_DEPLETED = "tab.depleted",

  // Streaming
  STREAM_OPENED = "stream.opened",
  STREAM_CLOSED = "stream.closed",

  // Subscription
  SUBSCRIPTION_CREATED = "subscription.created",
  SUBSCRIPTION_CHARGED = "subscription.charged",
  SUBSCRIPTION_CANCELLED = "subscription.cancelled",

  // Bounty
  BOUNTY_POSTED = "bounty.posted",
  BOUNTY_CLAIMED = "bounty.claimed",
  BOUNTY_AWARDED = "bounty.awarded",
  BOUNTY_EXPIRED = "bounty.expired",

  // General
  PAYMENT_RECEIVED = "payment.received",
  DEPOSIT_LOCKED = "deposit.locked",
  DEPOSIT_RETURNED = "deposit.returned",
  DISPUTE_FILED = "dispute.filed",
  DISPUTE_RESOLVED = "dispute.resolved",
  REPUTATION_UPDATED = "reputation.updated",
}

// Base payload for all events
export interface BaseEventPayload {
  event: EventType;
  event_id: string;          // unique, for idempotency
  chain: string;
  timestamp: number;         // unix seconds
  signature: string;         // EIP-712 signed by remit.md
}

// Event-specific payloads
export interface EscrowFundedPayload extends BaseEventPayload {
  event: EventType.ESCROW_FUNDED;
  data: {
    invoice_id: string;
    payer: string;
    payee: string;
    amount: string;          // USDC amount (string to avoid floating point)
    timeout: number;
    tx_hash: string;
  };
}

export interface EscrowReleasedPayload extends BaseEventPayload {
  event: EventType.ESCROW_RELEASED;
  data: {
    invoice_id: string;
    payer: string;
    payee: string;
    amount: string;
    fee: string;
    tx_hash: string;
  };
}

export interface EscrowTimeoutPayload extends BaseEventPayload {
  event: EventType.ESCROW_TIMEOUT;
  data: {
    invoice_id: string;
    payer: string;
    amount: string;
    tx_hash: string;
  };
}

export interface EscrowCancelledPayload extends BaseEventPayload {
  event: EventType.ESCROW_CANCELLED;
  data: {
    invoice_id: string;
    payer: string;
    mutual: boolean;
    fee: string;
    tx_hash: string;
  };
}

export interface EscrowDisputedPayload extends BaseEventPayload {
  event: EventType.ESCROW_DISPUTED;
  data: {
    invoice_id: string;
    filer: string;
    reason: string;
    tx_hash: string;
  };
}

export interface MilestoneReleasedPayload extends BaseEventPayload {
  event: EventType.MILESTONE_RELEASED;
  data: {
    invoice_id: string;
    milestone_index: number;
    amount: string;
    tx_hash: string;
  };
}

export interface ClaimStartConfirmedPayload extends BaseEventPayload {
  event: EventType.CLAIM_START_CONFIRMED;
  data: {
    invoice_id: string;
    payee: string;
    timestamp: number;
    tx_hash: string;
  };
}

export interface TabOpenedPayload extends BaseEventPayload {
  event: EventType.TAB_OPENED;
  data: {
    tab_id: string;
    payer: string;
    provider: string;
    limit: string;
    per_unit: string;
    expires: number;
    tx_hash: string;
  };
}

export interface TabChargePayload extends BaseEventPayload {
  event: EventType.TAB_CHARGE;
  data: {
    tab_id: string;
    amount: string;
    total_charged: string;
    remaining: string;
    call_count: number;
  };
}

export interface TabClosedPayload extends BaseEventPayload {
  event: EventType.TAB_CLOSED;
  data: {
    tab_id: string;
    total_charged: string;
    refund: string;
    fee: string;
    tx_hash: string;
  };
}

export interface TabDepletedPayload extends BaseEventPayload {
  event: EventType.TAB_DEPLETED;
  data: {
    tab_id: string;
    total_charged: string;
  };
}

export interface StreamOpenedPayload extends BaseEventPayload {
  event: EventType.STREAM_OPENED;
  data: {
    stream_id: string;
    payer: string;
    payee: string;
    rate: string;            // USD per second
    max_total: string;
    tx_hash: string;
  };
}

export interface StreamClosedPayload extends BaseEventPayload {
  event: EventType.STREAM_CLOSED;
  data: {
    stream_id: string;
    total_streamed: string;
    refund: string;
    fee: string;
    tx_hash: string;
  };
}

export interface SubscriptionCreatedPayload extends BaseEventPayload {
  event: EventType.SUBSCRIPTION_CREATED;
  data: {
    sub_id: string;
    payer: string;
    provider: string;
    amount: string;
    interval: number;
    tx_hash: string;
  };
}

export interface SubscriptionChargedPayload extends BaseEventPayload {
  event: EventType.SUBSCRIPTION_CHARGED;
  data: {
    sub_id: string;
    amount: string;
    next_charge_at: number;
    tx_hash: string;
  };
}

export interface SubscriptionCancelledPayload extends BaseEventPayload {
  event: EventType.SUBSCRIPTION_CANCELLED;
  data: {
    sub_id: string;
    canceller: string;
    tx_hash: string;
  };
}

export interface BountyPostedPayload extends BaseEventPayload {
  event: EventType.BOUNTY_POSTED;
  data: {
    bounty_id: string;
    poster: string;
    amount: string;
    task: string;
    deadline: number;
    tx_hash: string;
  };
}

export interface BountyClaimedPayload extends BaseEventPayload {
  event: EventType.BOUNTY_CLAIMED;
  data: {
    bounty_id: string;
    submitter: string;
    evidence_hash: string;
    tx_hash: string;
  };
}

export interface BountyAwardedPayload extends BaseEventPayload {
  event: EventType.BOUNTY_AWARDED;
  data: {
    bounty_id: string;
    winner: string;
    amount: string;
    fee: string;
    tx_hash: string;
  };
}

export interface BountyExpiredPayload extends BaseEventPayload {
  event: EventType.BOUNTY_EXPIRED;
  data: {
    bounty_id: string;
    amount: string;
    tx_hash: string;
  };
}

export interface PaymentReceivedPayload extends BaseEventPayload {
  event: EventType.PAYMENT_RECEIVED;
  data: {
    from: string;
    to: string;
    amount: string;
    memo?: string;
    tx_hash: string;
  };
}

export interface DepositLockedPayload extends BaseEventPayload {
  event: EventType.DEPOSIT_LOCKED;
  data: {
    deposit_id: string;
    depositor: string;
    provider: string;
    amount: string;
    expiry: number;
    tx_hash: string;
  };
}

export interface DepositReturnedPayload extends BaseEventPayload {
  event: EventType.DEPOSIT_RETURNED;
  data: {
    deposit_id: string;
    depositor: string;
    amount: string;
    tx_hash: string;
  };
}

export interface DisputeFiledPayload extends BaseEventPayload {
  event: EventType.DISPUTE_FILED;
  data: {
    invoice_id: string;
    filer: string;
    reason: string;
    evidence_hash: string;
    tx_hash: string;
  };
}

export interface DisputeResolvedPayload extends BaseEventPayload {
  event: EventType.DISPUTE_RESOLVED;
  data: {
    invoice_id: string;
    payer_amount: string;
    payee_amount: string;
    tx_hash: string;
  };
}

export interface ReputationUpdatedPayload extends BaseEventPayload {
  event: EventType.REPUTATION_UPDATED;
  data: {
    wallet: string;
    new_score: number;
    reason: string;
  };
}

// Webhook payload (wraps any event)
export interface WebhookPayload {
  event: EventType;
  event_id: string;
  invoice_id?: string;
  chain: string;
  timestamp: number;
  data: Record<string, unknown>;
  signature: string;
}

// Full union type for all payloads
export type EventPayload =
  | EscrowFundedPayload
  | EscrowReleasedPayload
  | EscrowTimeoutPayload
  | EscrowCancelledPayload
  | EscrowDisputedPayload
  | MilestoneReleasedPayload
  | ClaimStartConfirmedPayload
  | TabOpenedPayload
  | TabChargePayload
  | TabClosedPayload
  | TabDepletedPayload
  | StreamOpenedPayload
  | StreamClosedPayload
  | SubscriptionCreatedPayload
  | SubscriptionChargedPayload
  | SubscriptionCancelledPayload
  | BountyPostedPayload
  | BountyClaimedPayload
  | BountyAwardedPayload
  | BountyExpiredPayload
  | PaymentReceivedPayload
  | DepositLockedPayload
  | DepositReturnedPayload
  | DisputeFiledPayload
  | DisputeResolvedPayload
  | ReputationUpdatedPayload;
