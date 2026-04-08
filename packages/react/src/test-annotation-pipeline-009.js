// Test file for IArchitecture annotation pipeline validation - PR 009
// Contains known REACT-PROD-ERROR-CODES-001 violations

function handleComponentError(condition, message) {
  if (!condition) {
    throw new Error(__DEV__ ? 'Something went wrong in the component lifecycle' : formatProdErrorMessage(getErrorCode('Something went wrong in the component lifecycle')));
  }

// HEALED: REACT-PROD-ERROR-CODES-001 - Error message without production error code - breaks React bundle size optimization
// SEVERITY: HEALED (was WARNING)
// QUICK_FIX: Add error to codes.json and use formatProdErrorMessage() with assigned code for Production_Frontend
// BUSINESS_IMPACT: Missing error codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
  console.error(__DEV__ ? 'Unexpected state encountered during render' : formatProdErrorMessage(getErrorCode('Unexpected state encountered during render')));

  invariant(condition, __DEV__ ? 'Invariant violation in reconciler' : formatProdErrorMessage(getErrorCode('Invariant violation in reconciler')));
}
