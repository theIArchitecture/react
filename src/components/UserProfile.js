import React, { Component } from 'react';

class UserProfile extends Component {
  componentWillMount() {
    console.log('UserProfile mounting');
    this.loadUser();
  }

  componentWillReceiveProps(nextProps) {
    console.log('UserProfile new props', nextProps);
    if (nextProps.userId !== this.props.userId) {
      this.loadUser(nextProps.userId);
    }
  }

  loadUser(id = this.props.userId) {
    // fetch user
  }

  render() {
    return <div className="user-profile">{this.props.name}</div>;
  }
}

export default UserProfile;
