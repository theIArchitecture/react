/**
 * Component validation utilities.
 */

import { formatProdErrorMessage } from 'shared/formatProdErrorMessage';

export function validateProps(props) {
  if (!props.children) {
    throw new Error(formatProdErrorMessage(520));
  }

  if (props.onClick && typeof props.onClick !== 'function') {
    if (__DEV__) {
// VIOLATION: REACT-PROD-ERROR-CODES-001 - Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
// SEVERITY: WARNING
// ISSUES FOUND (7):
//   1. Line 14: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
//   2. Line 22: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
//   3. Line 28: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
//   4. Line 32: Error message without production error code - breaks React bundle size optimization [ERROR_LITERAL_MEDIUM: throw new Error('React component requires children prop to render content pro...]
//   5. Line 37: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
//   6. Line 42: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
//   7. Line 47: Error message without production error code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
// QUICK_FIX: Add error to codes.json and use formatProdErrorMessage() with assigned code for {{SILO:SECURITY_LEVEL}}
// BUSINESS_IMPACT: Missing error codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
      console.error('React component onClick prop must be a function');
    } else {
      console.error(formatProdErrorMessage(521));
    }
  }
}
or codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
      console.error('React component onClick prop must be a function');
    } else {
      console.error(formatProdErrorMessage(521));
    }
  }
}
act bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
// QUICK_FIX: Add error to codes.json and use formatProdErrorMessage() with assigned code for {{SILO:SECURITY_LEVEL}}
// BUSINESS_IMPACT: Missing error codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
    throw new Error('React component requires children prop to render content properly');
  }

  if (props.onClick && typeof props.onClick !== 'function') {
    if (__DEV__) {
      console.error('React component onClick prop must be a function');
    } else {
      console.error(formatProdErrorMessage(521));
    }
  }
}code - breaks React bundle size optimization [CONSOLE_ERROR_LITERAL: console.error('React component onClick prop must be a function')]
// SEVERITY: HEALED (was WARNING)
// QUICK_FIX: Add error to codes.json and use formatProdErrorMessage() with assigned code for {{SILO:SECURITY_LEVEL}}
// BUSINESS_IMPACT: Missing error codes prevent REACT_APPLICATION bundle optimization worth millions in performance - production errors become impossible to debug
// DOCS: https://github.com/facebook/react/blob/main/scripts/error-codes/README.md
    console.error('React component onClick prop must be a function');
  }
}
