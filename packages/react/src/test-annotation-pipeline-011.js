// Test file for IArchitecture annotation pipeline validation - PR 011
// Contains known REACT-PROD-ERROR-CODES-001 violations

function handleComponentError(condition, message) {
  if (!condition) {
    throw new Error('Something went wrong in the component lifecycle');
  }

  console.error('Unexpected state encountered during render');

  invariant(condition, 'Invariant violation in reconciler');
}
