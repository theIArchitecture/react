/**
 * Component validation utilities.
 */

import { formatProdErrorMessage } from 'shared/formatProdErrorMessage';

export function validateProps(props) {
  if (!props.children) {
    throw new Error(formatProdErrorMessage(1001));
  }

  if (props.onClick && typeof props.onClick !== 'function') {
    console.error(formatProdErrorMessage(1002));
  }
}
