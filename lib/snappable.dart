import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image;

class Snappable extends StatefulWidget {
  /// Widget to be snapped / スナップされるウィジェット
  final Widget child;

  /// Direction and range of snap effect / スナップエフェクトの方向と範囲
  /// (Where and how far will particles go) / (パーティクルはどこへ、どこまで行くのか）。
  final Offset offset;

  /// Duration of whole snap animation / スナップアニメーション全体の時間
  final Duration duration;

  /// How much can particle be randomized, / パーティクルはどこまでランダム化できるのか。
  /// For example if [offset] is (100, 100) and [randomDislocationOffset] is (10,10),
  /// Each layer can be moved to maximum between 90 and 110.  / 各レイヤーは90～110の間で最大に動かすことができます。
  final Offset randomDislocationOffset;

  /// Number of layers of images, / 画像のレイヤー数。
  /// The more of them the better effect but the more heavy it is for CPU  / 多ければ多いほど効果があるが、CPUが重くなる
  final int numberOfBuckets;

  /// Quick helper to snap widgets when touched / タッチしたときにウィジェットをスナップするクイックヘルパー
  /// If true wraps the widget in [GestureDetector] and starts [snap] when tapped / trueの場合、ウィジェットを[GestureDetector]でラップし、タップされたときに[snap]を開始します。
  /// Defaults to false / デフォルトはfalse
  final bool snapOnTap;

  /// Function that gets called when snap ends / スナップ終了時に呼び出される関数
  final VoidCallback onSnapped;

  const Snappable({
    required Key key,
    required this.child,
    this.offset = const Offset(64, -32),
    this.duration = const Duration(milliseconds: 5000),
    this.randomDislocationOffset = const Offset(64, 32),
    this.numberOfBuckets = 16,
    this.snapOnTap = false,
    required this.onSnapped,
  }) : super(key: key);

  @override
  SnappableState createState() => SnappableState();
}

class SnappableState extends State<Snappable>
    with SingleTickerProviderStateMixin {
  static const double _singleLayerAnimationLength = 0.6;
  static const double _lastLayerAnimationStart =
      1 - _singleLayerAnimationLength;

  bool get isGone => _animationController.isCompleted;

  /// Main snap effect controller / メインスナップエフェクトコントローラー
  late AnimationController _animationController;

  /// Key to get image of a [widget.child] / widget.child]の画像を取得するためのキーです。
  final GlobalKey _globalKey = GlobalKey();

  /// Layers of image 画像のレイヤー
  late List<Uint8List> _layers;

  /// Values from -1 to 1 to dislocate the layers a bit / -1から1までの値で、レイヤーを少しずらすことができます。
  late List<double> _randoms;

  /// Size of child widget /  子ウィジェットの大きさ。
  late Size size;

  @override
  void initState() {
    super.initState();
    _layers = [];
    _animationController = AnimationController(
      vsync: this,
      duration: widget.duration,
    );

    _animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onSnapped();
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.snapOnTap ? () => isGone ? reset() : snap() : null,
      child: Stack(
        children: <Widget>[
          ..._layers.map(_imageToWidget),
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              if (_animationController.isDismissed) {
                return child!;
              } else {
                return Container();
              }
            },
            child: RepaintBoundary(
              key: _globalKey,
              child: widget.child,
            ),
          )
        ],
      ),
    );
  }

  /// I am... INEVITABLE   /     ~Thanos 私は絶対だ！ ~サノス
  Future<void> snap() async {
    //get image from child / こどもからイメージをもらう
    final fullImage = await _getImageFromWidget();

    //create an image for every bucket / バケツごとに画像を作成する
    List<image.Image> _images = List<image.Image>.generate(
      widget.numberOfBuckets,
      (i) => image.Image(fullImage!.width, fullImage.height),
    );

    //for every line of pixels / 画素の行ごとに
    for (int y = 0; y < fullImage!.height; y++) {
      //generate weight list of probabilities determining
      //to which bucket should given pixels go / 与えられた画素がどのバケツに入るかを決定する確率の重みリストを生成する。
      List<int> weights = List.generate(
        widget.numberOfBuckets,
        (bucket) => _gauss(
          y / fullImage.height,
          bucket / widget.numberOfBuckets,
        ),
      );
      int sumOfWeights = weights.fold(0, (sum, el) => sum + el);

      //for every pixel in a line　 / 行の各画素に対して
      for (int x = 0; x < fullImage.width; x++) {
        //get the pixel from fullImage　fullImage / から画素を取得する
        int pixel = fullImage.getPixel(x, y);
        //choose a bucket for a pixel / バケツを選ぶ
        int imageIndex = _pickABucket(weights, sumOfWeights);
        //set the pixel from chosen bucket / 選択されたバケツから画素を設定する。
        _images[imageIndex].setPixel(x, y, pixel);
      }
    }

    _layers = await compute<List<image.Image>, List<Uint8List>>(
        _encodeImages, _images);

    //prepare random dislocations and set state / ランダムな転位を用意し、状態を設定する。
    setState(() {
      _randoms = List.generate(
        widget.numberOfBuckets,
        (i) => (math.Random().nextDouble() - 0.5) * 2,
      );
    });

    //give a short delay to draw images / 画像の描画に少し遅延を与える
    await Future.delayed(const Duration(milliseconds: 100));

    //start the snap! / スナップ開始！
    _animationController.forward();
  }

  /// I am... IRON MAN   ~Tony Stark　 /  私がアイアンマンだ。トニー・スターク
  void reset() {
    setState(() {
      _layers = [];
      _animationController.reset();
    });
  }

  Widget _imageToWidget(Uint8List layer) {
    //get layer's index in the list / リスト内のレイヤーのインデックスを取得する
    int index = _layers.indexOf(layer);

    //based on index, calculate when this layer should start and end / インデックスに基づき、このレイヤーの開始と終了のタイミングを計算します。
    double animationStart = (index / _layers.length) * _lastLayerAnimationStart;
    double animationEnd = animationStart + _singleLayerAnimationLength;

    //create interval animation using only part of whole animation / アニメーションの一部分だけを使ったインターバルアニメーションを作成する。
    CurvedAnimation animation = CurvedAnimation(
      parent: _animationController,
      curve: Interval(
        animationStart,
        animationEnd,
        curve: Curves.easeOut,
      ),
    );

    Offset randomOffset = widget.randomDislocationOffset.scale(
      _randoms[index],
      _randoms[index],
    );

    Animation<Offset> offsetAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: widget.offset + randomOffset,
    ).animate(animation);

    return AnimatedBuilder(
      animation: _animationController,
      child: Image.memory(layer),
      builder: (context, child) {
        return Transform.translate(
          offset: offsetAnimation.value,
          child: Opacity(
            opacity: math.cos(animation.value * math.pi / 2),
            child: child,
          ),
        );
      },
    );
  }

  /// Returns index of a randomly chosen bucket / ランダムに選ばれたバケツのインデックスを返します。
  int _pickABucket(List<int> weights, int sumOfWeights) {
    int rnd = math.Random().nextInt(sumOfWeights);
    int chosenImage = 0;
    for (int i = 0; i < widget.numberOfBuckets; i++) {
      if (rnd < weights[i]) {
        chosenImage = i;
        break;
      }
      rnd -= weights[i];
    }
    return chosenImage;
  }

  /// Gets an Image from a [child] and caches [size] for later us.So　　 / 　childから画像を取得し、[size]をキャッシュする。
  Future<image.Image?> _getImageFromWidget() async {
    RenderRepaintBoundary? boundary =
        _globalKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    //cache image for later / キャッシュイメージ
    size = boundary!.size;
    var img = await boundary.toImage();
    var byteData = await img.toByteData(format: ImageByteFormat.png);
    var pngBytes = byteData!.buffer.asUint8List();

    return image.decodeImage(pngBytes);
  }

  int _gauss(double center, double value) =>
      (1000 * math.exp(-(math.pow((value - center), 2) / 0.14))).round();
}

/// This is slow! Run it in separate isolate / これは遅い! 分離して実行する
List<Uint8List> _encodeImages(List<image.Image> images) {
  return images.map((img) => Uint8List.fromList(image.encodePng(img))).toList();
}
