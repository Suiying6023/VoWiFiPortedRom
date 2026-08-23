package android.telephony.data;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

import java.util.List;

/**
 * Compile-only stub for the @SystemApi hidden class
 * android.telephony.data.QualifiedNetworksService.
 * Not packaged into the APK; resolved from the framework at runtime.
 */
public abstract class QualifiedNetworksService extends Service {

    public static final String QUALIFIED_NETWORKS_SERVICE_INTERFACE =
            "android.telephony.data.QualifiedNetworksService";

    public abstract NetworkAvailabilityProvider onCreateNetworkAvailabilityProvider(int slotIndex);

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    public abstract class NetworkAvailabilityProvider implements AutoCloseable {
        private final int mSlotIndex;

        public NetworkAvailabilityProvider(int slotIndex) {
            mSlotIndex = slotIndex;
        }

        public final int getSlotIndex() {
            return mSlotIndex;
        }

        public final void updateQualifiedNetworkTypes(
                int apnTypes, List<Integer> qualifiedNetworkTypes) {
            // no-op in compile stub; framework implementation sends to telephony.
        }

        @Override
        public void close() {
        }
    }
}
