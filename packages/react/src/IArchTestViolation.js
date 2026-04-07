// Test file for iarch-pattern-healer validation
// Contains intentional violations of REACT-PROD-ERROR-CODES-001

function renderComponent(props) {
    if (!props.children) {
        throw new Error('React component requires children prop to render correctly');
    }

    if (typeof props.onClick !== 'function') {
        console.error('React component onClick prop must be a function type');
    }

    return props.children;
}

module.exports = { renderComponent };
