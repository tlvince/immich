import 'dart:math';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/asyncvalue_extensions.dart';
import 'package:immich_mobile/extensions/latlngbounds_extension.dart';
import 'package:immich_mobile/extensions/maplibrecontroller_extensions.dart';
import 'package:immich_mobile/modules/map/models/map_event.model.dart';
import 'package:immich_mobile/modules/map/models/map_marker.dart';
import 'package:immich_mobile/modules/map/providers/map_marker.provider.dart';
import 'package:immich_mobile/modules/map/providers/map_state.provider.dart';
import 'package:immich_mobile/modules/map/widgets/map_app_bar.dart';
import 'package:immich_mobile/modules/map/widgets/map_bottom_sheet.dart';
import 'package:immich_mobile/modules/map/widgets/map_theme_override.dart';
import 'package:immich_mobile/modules/map/widgets/positioned_asset_marker_icon.dart';
import 'package:immich_mobile/shared/models/asset.dart';
import 'package:immich_mobile/shared/views/immich_loading_overlay.dart';
import 'package:immich_mobile/utils/debounce.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class MapPage extends HookConsumerWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapController = useRef<MaplibreMapController?>(null);
    final markers = useRef<List<MapMarker>>([]);
    final markersInBounds = useRef<List<MapMarker>>([]);
    final bottomSheetStreamController = useStreamController<MapEvent>();
    final selectedMarker = useValueNotifier<_AssetMarkerMeta?>(null);
    final assetsDebouncer = useDebouncer();
    final isLoading = useProcessingOverlay();
    final markerDebouncer =
        useDebouncer(interval: const Duration(milliseconds: 800));
    final selectedAssets = useValueNotifier<Set<Asset>>({});

    // updates the markersInBounds value with the map markers that are visible in the current
    // map camera bounds
    Future<void> updateAssetsInBounds() async {
      // Guard map not created
      if (mapController.value == null) {
        return;
      }

      final bounds = await mapController.value!.getVisibleRegion();
      final inBounds = markers.value
          .where(
            (m) =>
                bounds.contains(LatLng(m.latLng.latitude, m.latLng.longitude)),
          )
          .toList();
      // Notify bottom sheet to update asset grid only when there are new assets
      if (markersInBounds.value.length != inBounds.length) {
        bottomSheetStreamController.add(
          MapAssetsInBoundsUpdated(
            inBounds.map((e) => e.assetRemoteId).toList(),
          ),
        );
      }
      markersInBounds.value = inBounds;
    }

    // removes all sources and layers and re-adds them with the updated markers
    Future<void> reloadLayers() async {
      if (mapController.value != null) {
        mapController.value!.reloadAllLayersForMarkers(markers.value);
      }
    }

    Future<void> loadMarkers() async {
      isLoading.value = true;
      markers.value = await ref.read(mapMarkersProvider.future);
      assetsDebouncer.run(updateAssetsInBounds);
      reloadLayers();
      isLoading.value = false;
    }

    useEffect(
      () {
        loadMarkers();
        return null;
      },
      [],
    );

    // Refetch markers when map state is changed
    ref.listen(mapStateNotifierProvider, (_, current) {
      if (current.shouldRefetchMarkers) {
        markerDebouncer.run(() {
          ref.invalidate(mapMarkersProvider);
          loadMarkers();
          ref.read(mapStateNotifierProvider.notifier).setRefetchMarkers(false);
        });
      }
    });

    // updates the selected markers position based on the current map camera
    Future<void> updateAssetMarkerPosition(
      MapMarker marker, {
      bool shouldAnimate = true,
    }) async {
      final assetPoint =
          await mapController.value!.toScreenLocation(marker.latLng);
      selectedMarker.value = _AssetMarkerMeta(
        point: assetPoint,
        marker: marker,
        shouldAnimate: shouldAnimate,
      );
      (assetPoint, marker, shouldAnimate);
    }

    // finds the nearest asset marker from the tap point and store it as the selectedMarker
    Future<void> onMarkerClicked(Point<double> point, LatLng coords) async {
      // Guard map not created
      if (mapController.value == null) {
        return;
      }
      final latlngBound =
          await mapController.value!.getBoundsFromPoint(point, 50);
      final marker = markersInBounds.value.firstWhereOrNull(
        (m) =>
            latlngBound.contains(LatLng(m.latLng.latitude, m.latLng.longitude)),
      );

      if (marker != null) {
        updateAssetMarkerPosition(marker);
      } else {
        // If no asset was previously selected and no new asset is available, close the bottom sheet
        if (selectedMarker.value == null) {
          bottomSheetStreamController.add(MapCloseBottomSheet());
        }
        selectedMarker.value = null;
      }
    }

    void onMapCreated(MaplibreMapController controller) async {
      mapController.value = controller;
      controller.addListener(() {
        if (controller.isCameraMoving && selectedMarker.value != null) {
          updateAssetMarkerPosition(
            selectedMarker.value!.marker,
            shouldAnimate: false,
          );
        }
      });
    }

    /// BOTTOM SHEET CALLBACKS

    Future<void> onMapMoved() async {
      assetsDebouncer.run(updateAssetsInBounds);
    }

    void onBottomSheetScrolled(String assetRemoteId) {
      final assetMarker = markersInBounds.value
          .firstWhereOrNull((m) => m.assetRemoteId == assetRemoteId);
      if (assetMarker != null) {
        updateAssetMarkerPosition(assetMarker);
      }
    }

    void onZoomToAsset(String assetRemoteId) {
      final assetMarker = markersInBounds.value
          .firstWhereOrNull((m) => m.assetRemoteId == assetRemoteId);
      if (mapController.value != null && assetMarker != null) {
        final latlng = LatLng(
          // Offset the latitude a little to show the marker just above the viewports center
          assetMarker.latLng.latitude - 0.02,
          assetMarker.latLng.longitude,
        );
        mapController.value!.animateCamera(
          CameraUpdate.newLatLngZoom(latlng, 12),
          duration: const Duration(milliseconds: 800),
        );
      }
    }

    void onAssetsSelected(bool selected, Set<Asset> selection) {
      selectedAssets.value = selected ? selection : {};
    }

    return MapThemeOveride(
      mapBuilder: (style) => Scaffold(
        extendBodyBehindAppBar: true,
        appBar: MapAppBar(selectedAssets: selectedAssets),
        body: Stack(
          children: [
            style.widgetWhen(
              onData: (style) => MaplibreMap(
                initialCameraPosition:
                    const CameraPosition(target: LatLng(0, 0)),
                styleString: style,
                // This is needed to update the selectedMarker's position on map camera updates
                // The changes are notified through the mapController ValueListener which is added in [onMapCreated]
                trackCameraPosition: true,
                onMapCreated: onMapCreated,
                onCameraIdle: onMapMoved,
                onMapClick: onMarkerClicked,
                onStyleLoadedCallback: reloadLayers,
                tiltGesturesEnabled: false,
                dragEnabled: false,
                myLocationEnabled: false,
                attributionButtonPosition: AttributionButtonPosition.TopRight,
                attributionButtonMargins: const Point(24, -5),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: selectedMarker,
              builder: (ctx, value, _) => value != null
                  ? PositionedAssetMarkerIcon(
                      point: value.point,
                      assetRemoteId: value.marker.assetRemoteId,
                      durationInMilliseconds: value.shouldAnimate ? 100 : 0,
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        bottomSheet: MapBottomSheet(
          mapEventStream: bottomSheetStreamController.stream,
          onGridAssetChanged: onBottomSheetScrolled,
          onZoomToAsset: onZoomToAsset,
          onAssetsSelected: onAssetsSelected,
          selectedAssets: selectedAssets,
        ),
      ),
    );
  }
}

class _AssetMarkerMeta {
  final Point<num> point;
  final MapMarker marker;
  final bool shouldAnimate;

  const _AssetMarkerMeta({
    required this.point,
    required this.marker,
    required this.shouldAnimate,
  });

  @override
  String toString() =>
      '_AssetMarkerMeta(point: $point, marker: $marker, shouldAnimate: $shouldAnimate)';
}
