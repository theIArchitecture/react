/**
 * Component validation utilities.
 */

export function validateProps(props) {
  if (!props.children) {
    throw new Error('React component requires children prop to render content properly');
  }

  if (props.onClick && typeof props.onClick !== 'function') {
// VIOLATION: REACT-PROD-ERROR-CODES-001 - Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
// SEVERITY: WARNING
// QUICK_FIX: Add error to codes.json and use formatProdErrorMessage() with assigned code for {{SILO:SECURITY_LEVEL}}
// BUSINESS_IMPACT: Missing error codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
    console.error('React component onClick prop must be a function');
  }
}
