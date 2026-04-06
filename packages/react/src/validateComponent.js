/**
 * Component validation utilities.
 */

export function validateProps(props) {
  if (!props.children) {
    throw new Error('React component requires children prop to render content properly');
  }

  if (props.onClick && typeof props.onClick !== 'function') {
    console.error('React component onClick prop must be a function');
  }
}
