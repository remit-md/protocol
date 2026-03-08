// Status enums used across all components

export enum PaymentType {
  DIRECT = "direct",
  ESCROW = "escrow",
  METERED = "metered",
  STREAMING = "streaming",
  SUBSCRIPTION = "subscription",
  BOUNTY = "bounty",
  DEPOSIT = "deposit",
}

export enum EscrowStatus {
  FUNDED = "funded",
  ACTIVE = "active",          // after CLAIM_START
  COMPLETED = "completed",    // released
  DISPUTED = "disputed",      // frozen
  CANCELLED = "cancelled",    // mutual or unilateral
  TIMED_OUT = "timed_out",   // timeout expired
}

export enum MilestoneStatus {
  PENDING = "pending",
  FUNDED = "funded",
  SUBMITTED = "submitted",
  RELEASED = "released",
  DISPUTED = "disputed",
}

export enum TabStatus {
  OPEN = "open",
  DEPLETED = "depleted",
  CLOSED = "closed",
  EXPIRED = "expired",
}

export enum StreamStatus {
  ACTIVE = "active",
  PAUSED = "paused",
  CLOSED = "closed",
}

export enum SubscriptionStatus {
  ACTIVE = "active",
  CANCELLED = "cancelled",
  EXPIRED = "expired",
}

export enum BountyStatus {
  OPEN = "open",
  CLAIMED = "claimed",
  AWARDED = "awarded",
  EXPIRED = "expired",
}

export enum DepositStatus {
  LOCKED = "locked",
  RETURNED = "returned",
  FORFEITED = "forfeited",
  EXPIRED = "expired",
}

export enum DisputeStatus {
  FILED = "filed",
  RESPONDED = "responded",
  ESCALATED = "escalated",
  RESOLVED = "resolved",
}

export enum DisputeReason {
  INCOMPLETE_DELIVERY = "INCOMPLETE_DELIVERY",
  WRONG_DELIVERABLE = "WRONG_DELIVERABLE",
  QUALITY_BELOW_SPEC = "QUALITY_BELOW_SPEC",
  NO_DELIVERY = "NO_DELIVERY",
  PAYMENT_NOT_RELEASED = "PAYMENT_NOT_RELEASED",
  TIMEOUT_UNFAIR = "TIMEOUT_UNFAIR",
  OVERCHARGE = "OVERCHARGE",
}

export enum WalletTier {
  STANDARD = "standard",
  PREFERRED = "preferred",    // hit $10K threshold
}

// Fee constants
export const FEE_RATE_STANDARD = 0.01;     // 1%
export const FEE_RATE_PREFERRED = 0.005;   // 0.5%
export const FEE_THRESHOLD = 10_000;       // $10,000/month
export const MIN_TRANSACTION = 0.01;       // $0.01
export const CANCELLATION_FEE = 0.001;     // 0.1%

// USDC has 6 decimals
export const USDC_DECIMALS = 6;

// Supported chains
export enum ChainId {
  BASE = 8453,
  BASE_SEPOLIA = 84532,
  ARBITRUM = 42161,
  ARBITRUM_SEPOLIA = 421614,
  OPTIMISM = 10,
  OPTIMISM_SEPOLIA = 11155420,
  POLYGON = 137,
  POLYGON_AMOY = 80002,
  ETHEREUM = 1,
  ETHEREUM_SEPOLIA = 11155111,
  LOCAL_ANVIL = 31337,
}

export const USDC_ADDRESSES: Record<number, string> = {
  [ChainId.BASE]: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  [ChainId.ARBITRUM]: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  [ChainId.OPTIMISM]: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
  [ChainId.POLYGON]: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
  [ChainId.ETHEREUM]: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
};

// Invoice schema (matches spec exactly)
export interface Invoice {
  id: string;
  chain: string;
  from_agent: string;       // payer wallet address
  to_agent: string;         // payee wallet address
  amount: number;            // USD-denominated
  type: PaymentType;
  task: string;
  evidence_uri?: string;
  escrow_timeout?: number;   // seconds
  fee_paid_by: "payer" | "payee" | "split";
  milestones?: Milestone[];
  splits?: Split[];
  signature: string;         // EIP-712
  protocol_version: string;
  nonce: string;
}

export interface Milestone {
  milestone_id: string;
  description: string;
  amount: number;
  evidence_uri?: string;
  timeout: number;          // seconds
  status: MilestoneStatus;
}

export interface Split {
  agent: string;            // payee wallet address
  amount: number;
  task: string;
  evidence_uri?: string;
}

export interface WebhookRegistration {
  url: string;
  events: string[];
  chains: string[];
  signature: string;
}
