// SPDX-License-Identifier: MIT
pragma circom 2.1.0;

include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/bitwise.circom";
include "circomlib/circuits/ecc.circom";

template ActiveRangeProof() {
    // ============================================================================
    // PUBLIC INPUTS (visible on-chain, minimal information disclosure)
    // ============================================================================
    signal input public_current_sqrt_price;
    signal input public_target_sqrt_price;
    signal input public_timestamp;
    signal input public_range_min_sqrt_price;
    signal input public_range_max_sqrt_price;
    signal input public_range_width_sqrt_price;
    
    // ============================================================================
    // PRIVATE INPUTS (hidden from public, only proof validity revealed)
    // ============================================================================
    signal input private_current_price;
    signal input private_target_price;
    signal input private_rebalance_timestamp;
    signal input private_price_variance;
    signal input private_range_width;
    signal input private_tick_lower;
    signal input private_tick_upper;
    
    // ============================================================================
    // OUTPUT: boolean proof validity
    // ============================================================================
    signal output proof_valid;
    
    // ============================================================================
    // INTERNAL SIGNALS FOR RANGE VALIDATION
    // ============================================================================
    signal internal_current_in_range;
    signal internal_target_in_range;
    signal internal_timestamp_valid;
    signal internal_price_variance_valid;
    signal internal_range_consistency;
    
    // ============================================================================
    // COMPONENT: Range Check for Current Price
    // Validates: range_min <= current_price <= range_max
    // ============================================================================
    component current_range_check = RangeCheck(
        min_val = public_range_min_sqrt_price,
        max_val = public_range_max_sqrt_price,
        check_val = private_current_price
    );
    
    // ============================================================================
    // COMPONENT: Range Check for Target Price
    // Validates: range_min <= target_price <= range_max
    // ============================================================================
    component target_range_check = RangeCheck(
        min_val = public_range_min_sqrt_price,
        max_val = public_range_max_sqrt_price,
        check_val = private_target_price
    );
    
    // ============================================================================
    // COMPONENT: Timestamp Validity Check
    // Validates: rebalance_timestamp <= current_timestamp AND
    //            rebalance_timestamp >= current_timestamp - max_age
    // ============================================================================
    component timestamp_check = TimestampValidator(
        current_timestamp = public_timestamp,
        rebalance_timestamp = private_rebalance_timestamp,
        max_age = 86400
    );
    
    // ============================================================================
    // COMPONENT: Price Variance Validation
    // Validates: price_variance <= max_allowed_variance (prevents extreme moves)
    // ============================================================================
    component variance_check = VarianceValidator(
        variance = private_price_variance,
        max_variance = 500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000......
    );
    
    // ============================================================================
    // COMPONENT: Range Width Consistency Check
    // Validates: range_width matches difference between max and min
    // ============================================================================
    component range_width_check = RangeWidthValidator(
        min_val = public_range_min_sqrt_price,
        max_val = public_range_max_sqrt_price,
        reported_width = public_range_width_sqrt_price
    );
    
    // ============================================================================
    // COMPONENT: Public/Private Input Consistency
    // Ensures public inputs match private inputs where required
    // ============================================================================
    component input_consistency = InputConsistency(
        public_sqrt_price = public_current_sqrt_price,
        private_price = private_current_price
    );
    
    // ============================================================================
    // COMPONENT: Final Proof Validity Aggregation
    // ============================================================================
    component proof_aggregator = ProofAggregator(
        current_in_range = internal_current_in_range,
        target_in_range = internal_target_in_range,
        timestamp_valid = internal_timestamp_valid,
        variance_valid = internal_price_variance_valid,
        range_consistent = internal_range_consistency,
        output = proof_valid
    );
    
    // ============================================================================
    // CONSTRAINTS: Link all components together
    // ============================================================================
    
    // Current price must be in range
    current_range_check.range_valid === 1;
    internal_current_in_range <== current_range_check.range_valid;
    
    // Target price must be in range
    target_range_check.range_valid === 1;
    internal_target_in_range <== target_range_check.range_valid;
    
    // Timestamp must be valid
    timestamp_check.valid === 1;
    internal_timestamp_valid <== timestamp_check.valid;
    
    // Price variance must be within acceptable bounds
    variance_check.valid === 1;
    internal_price_variance_valid <== variance_check.valid;
    
    // Range width must be consistent
    range_width_check.valid === 1;
    internal_range_consistent <== range_width_check.valid;
    
    // Input consistency check
    input_consistency.match === 1;
    
    // Final proof validity is AND of all checks
    proof_aggregator.valid === 1;
    
    // ============================================================================
    // TEMPLATE: Range Check Component
    // ============================================================================
    template RangeCheck(min_val, max_val, check_val) {
        signal input range_valid;
        
        // Check: min_val <= check_val
        component check_min = LessThanOrEqual();
        check_min.in[0] <== min_val;
        check_min.in[1] <== check_val;
        check_min.out === 1;
        
        // Check: check_val <= max_val
        component check_max = LessThanOrEqual();
        check_max.in[0] <== check_val;
        check_max.in[1] <== max_val;
        check_max.out === 1;
        
        // Range is valid if both checks pass
        range_valid <== check_min.out && check_max.out;
    }
    
    // ============================================================================
    // TEMPLATE: Timestamp Validator Component
    // ============================================================================
    template TimestampValidator(current_timestamp, rebalance_timestamp, max_age) {
        signal input valid;
        
        // Check: rebalance_timestamp <= current_timestamp
        component check_past = LessThanOrEqual();
        check_past.in[0] <== rebalance_timestamp;
        check_past.in[1] <== current_timestamp;
        check_past.out === 1;
        
        // Check: current_timestamp - rebalance_timestamp <= max_age
        component age_check = AgeValidator(
            current = current_timestamp,
            rebalance = rebalance_timestamp,
            max_age = max_age
        );
        age_check.valid === 1;
        
        valid <== check_past.out && age_check.valid;
    }
    
    // ============================================================================
    // TEMPLATE: Age Validator Component
    // ============================================================================
    template AgeValidator(current, rebalance, max_age) {
        signal input valid;
        
        // Calculate age = current - rebalance
        signal age;
        age <== current - rebalance;
        
        // Check: age <= max_age
        component age_check = LessThanOrEqual();
        age_check.in[0] <== age;
        age_check.in[1] <== max_age;
        age_check.out === 1;
        
        valid <== age_check.out;
    }
    
    // ============================================================================
    // TEMPLATE: Variance Validator Component
    // ============================================================================
    template VarianceValidator(variance, max_variance) {
        signal input valid;
        
        // Check: variance <= max_variance
        component variance_check = LessThanOrEqual();
        variance_check.in[0] <== variance;
        variance_check.in[1] <== max_variance;
        variance_check.out === 1;
        
        valid <== variance_check.out;
    }
    
    // ============================================================================
    // TEMPLATE: Range Width Validator Component
    // ============================================================================
    template RangeWidthValidator(min_val, max_val, reported_width) {
        signal input valid;
        
        // Calculate expected width = max_val - min_val
        signal expected_width;
        expected_width <== max_val - min_val;
        
        // Check: reported_width == expected_width
        component width_check = Equality();
        width_check.in[0] <== reported_width;
        width_check.in[1] <== expected_width;
        width_check.out === 1;
        
        valid <== width_check.out;
    }
    
    // ============================================================================
    // TEMPLATE: Input Consistency Component
    // ============================================================================
    template InputConsistency(public_sqrt_price, private_price) {
        signal input match;
        
        // Check: public_sqrt_price == private_price
        component consistency_check = Equality();
        consistency_check.in[0] <== public_sqrt_price;
        consistency_check.in[1] <== private_price;
        consistency_check.out === 1;
        
        match <== consistency_check.out;
    }
    
    // ============================================================================
    // TEMPLATE: Proof Aggregator Component
    // ============================================================================
    template ProofAggregator(current_in_range, target_in_range, timestamp_valid, variance_valid, range_consistent, output) {
        signal input valid;
        
        // All checks must pass for proof to be valid
        valid <== current_in_range && target_in_range && timestamp_valid && variance_valid && range_consistent;
        
        output <== valid;
    }
}

// ============================================================================
// MAIN TEMPLATE
// ============================================================================
component main = ActiveRangeProof();