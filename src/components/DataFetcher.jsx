import React, { Component } from 'react';

class DataFetcher extends Component {
  componentWillMount() {
    console.log('DataFetcher starting fetch');
    this.props.onFetch();
  }

  componentWillUpdate(nextProps, nextState) {
    console.log('DataFetcher will update', nextProps, nextState);
  }

  render() {
    return <div>{this.props.children}</div>;
  }
}

export default DataFetcher;
