// IArch test file - healable REACT-PROD-ERROR-CODES-001 violation
function validateComponent(props) {
  if (!props.children) {
    throw new Error('React component requires children prop to render correctly');
  }
  if (props.onClick && typeof props.onClick !== 'function') {
    console.error('React component onClick prop must be a function type');
  }
}
