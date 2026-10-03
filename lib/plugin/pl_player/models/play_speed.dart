enum PlaySpeed {
  pointFive(0.5),

  one(1.0),
  onePointFive(1.5),

  two(2.0),
  twoPointFive(2.5),
  three(3.0),
  four(4.0),
  eight(8.0),
  ;

  final double value;
  const PlaySpeed(this.value);
}
