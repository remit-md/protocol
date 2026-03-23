// Source of truth for all error codes across the protocol.
// Other languages/components generate from this file.

export enum ErrorCode {
  // Transaction errors (400/402/409/410)
  INSUFFICIENT_BALANCE = "INSUFFICIENT_BALANCE",
  BELOW_MINIMUM = "BELOW_MINIMUM",
  ESCROW_ALREADY_FUNDED = "ESCROW_ALREADY_FUNDED",
  ESCROW_NOT_FOUND = "ESCROW_NOT_FOUND",
  ESCROW_EXPIRED = "ESCROW_EXPIRED",
  // Chain errors (409/422)
  CHAIN_MISMATCH = "CHAIN_MISMATCH",
  CHAIN_UNSUPPORTED = "CHAIN_UNSUPPORTED",

  // Auth errors (401)
  INVALID_SIGNATURE = "INVALID_SIGNATURE",
  NONCE_REUSED = "NONCE_REUSED",
  TIMESTAMP_EXPIRED = "TIMESTAMP_EXPIRED",

  // Invoice errors (400/409)
  INVALID_INVOICE = "INVALID_INVOICE",
  DUPLICATE_INVOICE = "DUPLICATE_INVOICE",
  SELF_PAYMENT = "SELF_PAYMENT",
  INVALID_PAYMENT_TYPE = "INVALID_PAYMENT_TYPE",

  // Metered/streaming errors (402/404/410/422)
  TAB_DEPLETED = "TAB_DEPLETED",
  TAB_EXPIRED = "TAB_EXPIRED",
  TAB_NOT_FOUND = "TAB_NOT_FOUND",
  STREAM_NOT_FOUND = "STREAM_NOT_FOUND",
  RATE_EXCEEDS_CAP = "RATE_EXCEEDS_CAP",

  // Subscription errors (404/410)
  SUBSCRIPTION_CANCELLED = "SUBSCRIPTION_CANCELLED",
  SUBSCRIPTION_NOT_FOUND = "SUBSCRIPTION_NOT_FOUND",

  // Bounty errors (410/409/422)
  BOUNTY_EXPIRED = "BOUNTY_EXPIRED",
  BOUNTY_CLAIMED = "BOUNTY_CLAIMED",
  BOUNTY_MAX_ATTEMPTS = "BOUNTY_MAX_ATTEMPTS",

// Rate limiting (429)
  RATE_LIMITED = "RATE_LIMITED",

  // Cancellation errors (409)
  CANCEL_BLOCKED_CLAIM_START = "CANCEL_BLOCKED_CLAIM_START",
  CANCEL_BLOCKED_EVIDENCE = "CANCEL_BLOCKED_EVIDENCE",

  // Protocol errors (422)
  VERSION_MISMATCH = "VERSION_MISMATCH",
}

export interface ErrorMetadata {
  code: ErrorCode;
  httpStatus: number;
  message: string;
}

export const ERROR_METADATA: Record<ErrorCode, ErrorMetadata> = {
  [ErrorCode.INSUFFICIENT_BALANCE]: {
    code: ErrorCode.INSUFFICIENT_BALANCE,
    httpStatus: 402,
    message: "Wallet does not have enough USDC for this transaction + fee.",
  },
  [ErrorCode.BELOW_MINIMUM]: {
    code: ErrorCode.BELOW_MINIMUM,
    httpStatus: 400,
    message: "Transaction amount is below $0.01 minimum.",
  },
  [ErrorCode.ESCROW_ALREADY_FUNDED]: {
    code: ErrorCode.ESCROW_ALREADY_FUNDED,
    httpStatus: 409,
    message: "This invoice already has a funded escrow.",
  },
  [ErrorCode.ESCROW_NOT_FOUND]: {
    code: ErrorCode.ESCROW_NOT_FOUND,
    httpStatus: 404,
    message: "No escrow exists for this invoice ID.",
  },
  [ErrorCode.ESCROW_EXPIRED]: {
    code: ErrorCode.ESCROW_EXPIRED,
    httpStatus: 410,
    message: "Escrow timeout has passed. Funds already returned.",
  },
[ErrorCode.CHAIN_MISMATCH]: {
    code: ErrorCode.CHAIN_MISMATCH,
    httpStatus: 409,
    message: "Payer and payee are on different chains. Same-chain required.",
  },
  [ErrorCode.CHAIN_UNSUPPORTED]: {
    code: ErrorCode.CHAIN_UNSUPPORTED,
    httpStatus: 422,
    message: "Requested chain is not supported.",
  },
  [ErrorCode.INVALID_SIGNATURE]: {
    code: ErrorCode.INVALID_SIGNATURE,
    httpStatus: 401,
    message: "EIP-712 signature verification failed.",
  },
  [ErrorCode.NONCE_REUSED]: {
    code: ErrorCode.NONCE_REUSED,
    httpStatus: 401,
    message: "This nonce has already been used. Increment and retry.",
  },
  [ErrorCode.TIMESTAMP_EXPIRED]: {
    code: ErrorCode.TIMESTAMP_EXPIRED,
    httpStatus: 401,
    message: "Request timestamp is too old. Resend with current time.",
  },
  [ErrorCode.INVALID_INVOICE]: {
    code: ErrorCode.INVALID_INVOICE,
    httpStatus: 400,
    message: "Invoice JSON does not match schema.",
  },
  [ErrorCode.DUPLICATE_INVOICE]: {
    code: ErrorCode.DUPLICATE_INVOICE,
    httpStatus: 400,
    message: "An invoice with this ID already exists.",
  },
  [ErrorCode.SELF_PAYMENT]: {
    code: ErrorCode.SELF_PAYMENT,
    httpStatus: 400,
    message: "Payer and payee cannot be the same wallet.",
  },
  [ErrorCode.INVALID_PAYMENT_TYPE]: {
    code: ErrorCode.INVALID_PAYMENT_TYPE,
    httpStatus: 400,
    message: "Unknown payment type.",
  },
  [ErrorCode.TAB_DEPLETED]: {
    code: ErrorCode.TAB_DEPLETED,
    httpStatus: 402,
    message: "Metered tab has no remaining funds.",
  },
  [ErrorCode.TAB_EXPIRED]: {
    code: ErrorCode.TAB_EXPIRED,
    httpStatus: 410,
    message: "Metered tab has expired.",
  },
  [ErrorCode.TAB_NOT_FOUND]: {
    code: ErrorCode.TAB_NOT_FOUND,
    httpStatus: 404,
    message: "No active tab for this counterparty.",
  },
  [ErrorCode.STREAM_NOT_FOUND]: {
    code: ErrorCode.STREAM_NOT_FOUND,
    httpStatus: 404,
    message: "No active stream for this counterparty.",
  },
  [ErrorCode.RATE_EXCEEDS_CAP]: {
    code: ErrorCode.RATE_EXCEEDS_CAP,
    httpStatus: 422,
    message: "Streaming rate exceeds the safety cap set by payer.",
  },
  [ErrorCode.SUBSCRIPTION_CANCELLED]: {
    code: ErrorCode.SUBSCRIPTION_CANCELLED,
    httpStatus: 410,
    message: "This subscription has been cancelled.",
  },
  [ErrorCode.SUBSCRIPTION_NOT_FOUND]: {
    code: ErrorCode.SUBSCRIPTION_NOT_FOUND,
    httpStatus: 404,
    message: "No active subscription found.",
  },
  [ErrorCode.BOUNTY_EXPIRED]: {
    code: ErrorCode.BOUNTY_EXPIRED,
    httpStatus: 410,
    message: "Bounty deadline has passed.",
  },
  [ErrorCode.BOUNTY_CLAIMED]: {
    code: ErrorCode.BOUNTY_CLAIMED,
    httpStatus: 409,
    message: "Bounty has already been claimed by another agent.",
  },
  [ErrorCode.BOUNTY_MAX_ATTEMPTS]: {
    code: ErrorCode.BOUNTY_MAX_ATTEMPTS,
    httpStatus: 422,
    message: "Maximum submission attempts reached for this bounty.",
  },
[ErrorCode.RATE_LIMITED]: {
    code: ErrorCode.RATE_LIMITED,
    httpStatus: 429,
    message: "Too many requests.",
  },
  [ErrorCode.CANCEL_BLOCKED_CLAIM_START]: {
    code: ErrorCode.CANCEL_BLOCKED_CLAIM_START,
    httpStatus: 409,
    message: "Cannot unilaterally cancel — payee has called CLAIM_START.",
  },
  [ErrorCode.CANCEL_BLOCKED_EVIDENCE]: {
    code: ErrorCode.CANCEL_BLOCKED_EVIDENCE,
    httpStatus: 409,
    message: "Cannot cancel — evidence has been submitted.",
  },
  [ErrorCode.VERSION_MISMATCH]: {
    code: ErrorCode.VERSION_MISMATCH,
    httpStatus: 422,
    message: "Unsupported protocol version.",
  },
};
